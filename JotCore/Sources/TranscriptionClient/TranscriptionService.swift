// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One pipeline for Gemini and editable compatible API profiles.
public struct TranscriptionService: TranscriptionServicing {
    private let settings: SettingsStore
    private let apiKey: @Sendable (ModelEndpoint) -> String?
    private let session: URLSession?
    private let dictionary: DictionaryStore

    public init(settings: SettingsStore = SettingsStore(),
                apiKey: @escaping @Sendable (ModelEndpoint) -> String? = { KeychainStore.loadAPIKey(account: $0.credentialAccount) },
                session: URLSession? = nil, dictionary: DictionaryStore = DictionaryStore()) {
        self.settings = settings
        self.apiKey = apiKey
        self.session = session
        self.dictionary = dictionary
    }

    public func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
        try await transcribe(audioURL: audioURL, durationSeconds: durationSeconds, context: context, onRawTranscript: { _ in })
    }

    public func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext,
                           onRawTranscript: @escaping @Sendable (String) async -> Void) async throws -> TranscriptionResult {
        let configuration = context.configuration ?? settings.transcriptionConfiguration
        let endpoint = configuration.recognition
        try endpoint.validate()
        if let language = configuration.explicitLanguage,
           language.range(of: "^[a-z][a-z0-9_-]{1,19}$", options: .regularExpression) == nil {
            throw TranscriptionError.badRequest(JotL10n.text("Укажите код языка, например ru или en, либо выберите Авто."))
        }
        let isGemini = endpoint.recognitionAPI == .gemini || endpoint.recognitionAPI == .geminiLegacy
        if isGemini, configuration.explicitLanguage != nil {
            // Gemini language_codes silently changes smart behaviour. Never send it speculatively.
            throw TranscriptionError.badRequest(JotL10n.text("Для Gemini поддерживается автоматическое определение языка. Для явного языка выберите API транскрибации файла."))
        }
        guard let key = apiKey(endpoint), !key.isEmpty else { throw TranscriptionError.auth }
        let prepared = Task.detached(priority: .userInitiated) {
            if isGemini {
                let target = FileManager.default.temporaryDirectory.appendingPathComponent("jot-\(UUID().uuidString).flac")
                defer { try? FileManager.default.removeItem(at: target) }
                let output = try FLACEncoder.encode(cafURL: audioURL, flacURL: target)
                return try Data(contentsOf: output.url)
            }
            return try AudioUploadEncoder.wav(from: audioURL)
        }
        let audio = try await withTaskCancellationHandler(operation: { try await prepared.value }, onCancel: { prepared.cancel() })
        try Task.checkCancellation()
        // WAV 16k/mono/Int16 at the ten-minute capture cap fits under 25 MB.
        guard audio.count <= 24_000_000 else { throw TranscriptionError.badRequest(JotL10n.text("Запись слишком велика для одного запроса. Аудио сохранено.")) }
        let gemini = GeminiClient(apiKey: { key })
        let compatible = CompatibleAPIClient(apiKey: { key }, session: session)
        let vocabulary = dictionary.sanitizedVocabulary()
        let deadline = TimeoutPolicy.overallDeadline(audioDuration: durationSeconds)

        func send(_ terms: [String]) async throws -> String {
            if endpoint.recognitionAPI == .geminiLegacy {
                return try await gemini.transcribe(flacData: audio, model: endpoint.model, endpoint: endpoint.url!,
                                                  deadline: deadline, customVocabulary: terms)
            }
            if endpoint.recognitionAPI == .gemini {
                return try await gemini.transcribeInteraction(audio: audio, model: endpoint.model, endpoint: endpoint.url!,
                                                             mode: configuration.nativeSmart ? .smart : .verbatim,
                                                             customVocabulary: terms, deadline: deadline)
            }
            return try await compatible.transcribe(audio: audio, endpoint: endpoint,
                                                    language: configuration.explicitLanguage,
                                                    vocabulary: terms, duration: durationSeconds, deadline: deadline)
        }
        func attempt() async throws -> String {
            do { return try await send(vocabulary) }
            catch TranscriptionError.badRequest where isGemini && !vocabulary.isEmpty {
                return try await send([]) // Keep dictation working if Google rejects vocabulary.
            }
        }
        var raw: String
        do { raw = try await attempt() }
        catch let error as TranscriptionError {
            switch error {
            case .network, .timeout:
                try await Task.sleep(nanoseconds: 500_000_000)
                raw = try await attempt()
            default: throw error
            }
        }
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty, durationSeconds >= 0.6 {
            raw = try await attempt().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !raw.isEmpty else { throw TranscriptionError.emptyTranscript }
        try Task.checkCancellation()
        // Save the independent reference before the optional, fallible rewrite.
        await onRawTranscript(raw)
        let cleaned = try await clean(raw, configuration: configuration, context: context)
        return TranscriptionResult(rawTranscript: raw, cleanedTranscript: cleaned, modelID: endpoint.model)
    }

    public func clean(_ raw: String, configuration: TranscriptionConfiguration,
                      context: DictationContext) async throws -> String {
        try Task.checkCancellation()
        let fallback = ReplacementEngine.apply(dictionary.replacementRules(), to: raw)
        guard configuration.cleanupEnabled else { return fallback }
        let endpoint = configuration.effectiveCleanup
        let prompt = PromptV1.cleanupPrompt(raw: raw,
                                           tone: configuration.matchTone ? PromptV1.toneCategory(forBundleID: context.targetAppBundleID) : .neutral,
                                           vocabulary: dictionary.sanitizedVocabulary(), spellings: dictionary.spellings())
        do {
            try endpoint.validate()
            guard let key = apiKey(endpoint), !key.isEmpty else { return fallback }
            // One budget for the complete cleanup operation, including any 429 wait/retry.
            let deadline = configuration.cleanupTimeout
            let response = try await GeminiClient.withDeadline(seconds: deadline) { [session] in
                if endpoint.provider == .gemini {
                    let client = GeminiClient(apiKey: { key })
                    return try await client.cleanup(prompt: prompt, model: endpoint.model,
                                                    endpoint: endpoint.url!, deadline: deadline)
                } else {
                    let client = CompatibleAPIClient(apiKey: { key }, session: session)
                    return try await client.cleanup(prompt: prompt, endpoint: endpoint, deadline: deadline)
                }
            }
            try Task.checkCancellation()
            let text = ValidationGate.stripArtifacts(response)
            guard ValidationGate.validate(raw: raw, cleaned: text).accepted else {
                let trips = settings.recordCleanupGateTrip(endpoint: endpoint)
                // Only turn off the CURRENT formatter if it is the one that failed.
                var current = settings.transcriptionConfiguration
                if trips >= 3, current.cleanupEnabled, current.effectiveCleanup == endpoint {
                    current.cleanupEnabled = false
                    settings.setTranscriptionConfiguration(current)
                    NotificationCenter.default.post(name: .gtSmartFormattingAutoDegraded, object: nil)
                }
                return fallback
            }
            return ReplacementEngine.apply(dictionary.replacementRules(), to: text)
        } catch is CancellationError { throw CancellationError() }
        catch { return fallback } // Never let the optional pass cost a usable transcript.
    }
}
