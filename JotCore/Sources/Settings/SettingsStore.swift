// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

public extension Notification.Name {
    /// Posted after any SettingsStore write and after Keychain API-key writes,
    /// with `object` = the key ("showIdleIndicator", "apiKey", …). Runtime
    /// surfaces that render a setting (pill, status line, hotkey engine) observe
    /// this so toggles take effect the moment they're flipped — never "on the
    /// next unrelated transition". (gateTrips bookkeeping is exempt: nothing
    /// renders it.)
    static let gtSettingDidChange = Notification.Name("com.ammaar.jot.setting-changed")

    /// Posted when the gate auto-disables the opt-in tone pass (3 trips in 24h)
    /// so the app can tell the user instead of silently dropping it. Native smart
    /// transcription is unaffected — the user loses an extra, not their words.
    static let gtSmartFormattingAutoDegraded = Notification.Name("com.ammaar.jot.auto-degraded")
}

/// UserDefaults-backed settings (M3 minimal; the Settings UI lands at M7).
/// Endpoint + model IDs are overridable because preview models get renamed.
public struct SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var interfaceLanguage: InterfaceLanguage {
        defaults.string(forKey: "interfaceLanguage").flatMap(InterfaceLanguage.init(rawValue:)) ?? .russian
    }
    public func setInterfaceLanguage(_ language: InterfaceLanguage) {
        set(language.rawValue, forKey: "interfaceLanguage")
    }

    public var transcriptionConfiguration: TranscriptionConfiguration {
        if let data = defaults.data(forKey: "transcriptionConfiguration"),
           let configuration = try? JSONDecoder().decode(TranscriptionConfiguration.self, from: data) {
            return configuration
        }
        // Reading old installations is side-effect free; migration writes once at launch.
        return legacyTranscriptionConfiguration
    }

    public func setTranscriptionConfiguration(_ configuration: TranscriptionConfiguration) {
        if configuration.cleanupEnabled && !transcriptionConfiguration.cleanupEnabled {
            let endpoint = configuration.effectiveCleanup
            defaults.removeObject(forKey: "cleanupGateTrips." + endpoint.credentialAccount + "." + endpoint.model)
        }
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        set(data, forKey: "transcriptionConfiguration")
    }

    public var legacyTranscriptionConfiguration: TranscriptionConfiguration {
        if let data = defaults.data(forKey: "legacyTranscriptionConfiguration"),
           let configuration = try? JSONDecoder().decode(TranscriptionConfiguration.self, from: data) {
            return configuration
        }
        let legacy = geminiConfig
        var configuration = TranscriptionConfiguration()
        configuration.recognition.baseURL = legacy.endpoint.absoluteString
        configuration.recognition.model = legacy.transcribeModel
        configuration.recognition.recognitionAPI = defaults.bool(forKey: "legacyTranscribeEndpoint") ? .geminiLegacy : .gemini
        configuration.cleanup.model = legacy.cleanupModel
        configuration.cleanupEnabled = defaults.bool(forKey: "smartCleanupPass")
        configuration.nativeSmart = defaults.object(forKey: "smartTranscription") as? Bool ?? true
        configuration.matchTone = configuration.cleanupEnabled
        return configuration
    }

    public func migrateAPISettings() {
        let legacy = legacyTranscriptionConfiguration
        if defaults.data(forKey: "legacyTranscriptionConfiguration") == nil,
           let data = try? JSONEncoder().encode(legacy) {
            defaults.set(data, forKey: "legacyTranscriptionConfiguration")
        }
        guard defaults.data(forKey: "transcriptionConfiguration") == nil else { return }
        if legacy.recognition.credentialAccount != "gemini-api-key", let key = KeychainStore.loadAPIKey() {
            guard KeychainStore.saveAPIKey(key, account: legacy.recognition.credentialAccount) else { return }
        }
        setTranscriptionConfiguration(legacy)
    }

    private func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .gtSettingDidChange, object: key)
    }

    /// Legacy override parsing for migration only. New API URLs use ModelEndpoint.
    public static func usableEndpointURL(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return nil
        }
        return url
    }

    /// True once the user finished onboarding — a deliberate "I'll add it later"
    /// must not re-trap them in the wizard every launch.
    public var hasCompletedOnboarding: Bool {
        defaults.bool(forKey: "hasCompletedOnboarding")
    }

    public func setHasCompletedOnboarding(_ done: Bool) {
        set(done, forKey: "hasCompletedOnboarding")
    }

    private var geminiConfig: GeminiConfig {
        var config = GeminiConfig()
        if let url = Self.usableEndpointURL(defaults.string(forKey: "endpointOverride")) {
            config.endpoint = url
        }
        if let model = defaults.string(forKey: "transcribeModelOverride"), !model.isEmpty {
            config.transcribeModel = model
        }
        if let model = defaults.string(forKey: "cleanupModelOverride"), !model.isEmpty {
            config.cleanupModel = model
        }
        return config
    }

    /// Double-tap the dictation key to lock hands-free. OFF by default: firm taps
    /// routinely exceed the hold threshold, misreading tap-tap as hold→finalize
    /// (dogfood). The timing-free gesture is Space-while-holding.
    public var doubleTapLockEnabled: Bool {
        defaults.object(forKey: "doubleTapLock") as? Bool ?? false
    }

    public func setDoubleTapLock(_ enabled: Bool) {
        set(enabled, forKey: "doubleTapLock")
    }

    /// Show the resting dot at the bottom of the screen when idle. Off = the pill
    /// only appears while dictating.
    public var showIdleIndicator: Bool {
        defaults.object(forKey: "showIdleIndicator") as? Bool ?? true
    }

    public func setShowIdleIndicator(_ show: Bool) {
        set(show, forKey: "showIdleIndicator")
    }

    public var soundsEnabled: Bool {
        defaults.object(forKey: "soundsEnabled") as? Bool ?? true
    }

    public func setSoundsEnabled(_ enabled: Bool) {
        set(enabled, forKey: "soundsEnabled")
    }

    public var hotkeyKey: HotkeyKey {
        (defaults.string(forKey: "hotkeyKey")).flatMap(HotkeyKey.init(rawValue:)) ?? .fn
    }

    /// Native `mode: "smart"` — the default transcription path.
    public var smartTranscriptionEnabled: Bool {
        transcriptionConfiguration.nativeSmart
    }

    public func setSmartTranscription(_ enabled: Bool) {
        var configuration = transcriptionConfiguration
        configuration.nativeSmart = enabled
        setTranscriptionConfiguration(configuration)
        NotificationCenter.default.post(name: .gtSettingDidChange, object: "smartTranscription")
    }

    /// The opt-in second pass through the cleanup model — this is what carries
    /// per-app tone. Off by default: it costs a round trip and sends the
    /// transcript text a second time.
    public var smartCleanupPassEnabled: Bool {
        transcriptionConfiguration.cleanupEnabled
    }

    public func setSmartCleanupPass(_ enabled: Bool) {
        if enabled {
            // A deliberate re-enable is a clean slate. This moved here with the
            // gate counter: auto-degrade now switches THIS flag off, so leaving
            // the clear on setSmartFormatting would resurrect the bug where one
            // stale trip inside the old 24h window instantly re-degrades.
            defaults.removeObject(forKey: "gateTrips")
        }
        var configuration = transcriptionConfiguration
        configuration.cleanupEnabled = enabled
        setTranscriptionConfiguration(configuration)
        NotificationCenter.default.post(name: .gtSettingDidChange, object: "smartCleanupPass")
    }

    /// Compatibility setter for existing debug links. The UI uses recognitionAPI.
    public func setLegacyTranscribeEndpoint(_ enabled: Bool) {
        var configuration = transcriptionConfiguration
        configuration.recognition.recognitionAPI = enabled ? .geminiLegacy : .gemini
        setTranscriptionConfiguration(configuration)
        NotificationCenter.default.post(name: .gtSettingDidChange, object: "legacyTranscribeEndpoint")
    }

    public func setHotkeyKey(_ key: HotkeyKey) {
        set(key.rawValue, forKey: "hotkeyKey")
    }

    /// Experimental: judge speech RELATIVE to the room instead of against fixed
    /// thresholds that assume a quiet one, and (once probed) let macOS suppress
    /// background voices. Off by default until dogfood data earns the flip.
    ///
    /// One key gates every behaviour in the noise work, so there is exactly one
    /// thing to turn on, one thing to turn off, and one thing to flip when the
    /// numbers are in. The measurements it would act on are recorded either way —
    /// `NoiseFloorEstimator` runs unconditionally.
    public var experimentalNoiseHandling: Bool {
        defaults.bool(forKey: "experimentalNoiseHandling")
    }

    public func setExperimentalNoiseHandling(_ enabled: Bool) {
        set(enabled, forKey: "experimentalNoiseHandling")
    }

    /// Stream audio to the Live API over a WebSocket and show words as they are
    /// spoken, instead of uploading the clip at key-up.
    ///
    /// Experimental and off by default. It is a genuinely different transport
    /// with a genuinely different failure surface — a socket can die mid-sentence
    /// where an upload either succeeds or does not — so it earns its way on by
    /// dogfooding, not by being the new default.
    ///
    /// Turning this on never risks words. The CAF is written exactly as before,
    /// and a live stream that ends any way other than cleanly is discarded in
    /// favour of the batch upload over that file.
    public var liveTranscription: Bool {
        defaults.bool(forKey: "liveTranscription")
    }

    public func setLiveTranscription(_ enabled: Bool) {
        set(enabled, forKey: "liveTranscription")
    }

    /// Only the supported native Gemini configuration can enable Live.
    public var liveTranscriptionActive: Bool {
        liveTranscription && transcriptionConfiguration.permitsLive
    }

    /// Days to keep audio files (transcripts are kept until deleted). 0 = forever.
    public var audioRetentionDays: Int {
        defaults.object(forKey: "audioRetentionDays") as? Int ?? 7
    }

    public func setAudioRetentionDays(_ days: Int) {
        set(days, forKey: "audioRetentionDays")
    }

    public func recordCleanupGateTrip(endpoint: ModelEndpoint, now: Date = Date()) -> Int {
        let key = "cleanupGateTrips." + endpoint.credentialAccount + "." + endpoint.model
        var trips = (defaults.array(forKey: key) as? [Date]) ?? []
        trips = trips.filter { now.timeIntervalSince($0) < 86_400 }
        trips.append(now)
        defaults.set(trips, forKey: key)
        return trips.count
    }

}
