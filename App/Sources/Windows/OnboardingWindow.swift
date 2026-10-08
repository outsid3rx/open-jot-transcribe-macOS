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

import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI
import JotCore

/// First-launch onboarding: welcome → key → mic → accessibility → Globe key →
/// try it → done. Warm, plain-spoken, one screen at a time (experience spec §5).
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private var onClosed: (() -> Void)?

    convenience init(
        onFinished: @escaping () -> Void,
        onClosed: @escaping () -> Void,
        latestRecord: @escaping () -> DictationRecord? = { nil }
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        // Pin the SwiftUI content to the design size — assigning an NSHostingView
        // whose fitting size is unbounded (Spacer + maxHeight: .infinity) resizes
        // the window to near screen height.
        window.contentView = NSHostingView(
            rootView: OnboardingFlow(onFinished: onFinished, latestRecord: latestRecord)
                .frame(width: 640, height: 560)
        )
        window.setContentSize(NSSize(width: 640, height: 560))
        window.center()
        // Setup sends people into System Settings twice (microphone, then
        // accessibility), and every trip steals focus. Jot is an accessory app,
        // so it has no Dock icon and no Cmd-Tab entry — once this window fell
        // behind System Settings there was NO way back to it except finding the
        // menu bar icon, and users reported exactly that. Floating keeps it in
        // sight the whole time, which also means they watch the checkmark flip.
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        self.init(window: window)
        self.onClosed = onClosed
        window.delegate = self
    }

    /// Red-button close mid-flow must stop any live resources — the mic-test
    /// engine kept the mic (and the orange dot) alive forever (audit #6).
    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.post(name: .onboardingWindowClosed, object: nil)
        onClosed?()
    }
}

extension Notification.Name {
    static let onboardingWindowClosed = Notification.Name("com.ammaar.jot.onboarding.closed")
    static let onboardingJumpToScreen = Notification.Name("com.ammaar.jot.onboarding.jump")
}

private struct OnboardingFlow: View {
    let onFinished: () -> Void
    var latestRecord: () -> DictationRecord? = { nil }

    enum Screen: Int, CaseIterable {
        case welcome, apiKey, microphone, accessibility, globeKey, howTo, tryIt, done
    }

    @State private var screen: Screen = .welcome
    /// Where we came from, so Back honours screens that were skipped (the Globe
    /// step) instead of guessing with rawValue - 1. Reported from the wild:
    /// "I accidentally skipped past the key screen and I can't get back."
    @State private var backStack: [Screen] = []
    @Environment(\.colorScheme) private var scheme
    private var grad: CGFloat { scheme == .dark ? 25 : 0 }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: JotUI.Spacing.l)
            currentScreen
                .frame(maxWidth: 480)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .id(screen)
            Spacer()
            progressDots
                .padding(.bottom, JotUI.Spacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(JotUI.Colors.windowBackground)
        .overlay(alignment: .topLeading) {
            if !backStack.isEmpty {
                Button(action: goBack) {
                    Label(JotL10n.text("Back"), systemImage: "chevron.left")
                        .font(JotUI.TypeScale.body())
                        .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                        .padding(.horizontal, JotUI.Spacing.s)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: .command)
                .padding(.leading, JotUI.Spacing.s)
                .padding(.top, JotUI.Spacing.s)
                .transition(.opacity)
            }
        }
        .animation(JotMotion.expressiveDefaultSpatial, value: screen)
        // jot://onboarding/<n> — deep-link to a screen (automation + UI checks).
        .onReceive(NotificationCenter.default.publisher(for: .onboardingJumpToScreen)) { note in
            if let index = note.object as? Int, let target = Screen(rawValue: index) {
                backStack.append(screen)
                screen = target
            }
        }
    }

    @ViewBuilder
    private var currentScreen: some View {
        switch screen {
        case .welcome: WelcomeScreen(onNext: { advance() })
        case .apiKey: APIKeyScreen(onNext: { advance() })
        case .microphone: MicScreen(onNext: { advance() })
        case .accessibility: AccessibilityScreen(onNext: { advance() })
        case .globeKey: GlobeKeyScreen(onNext: { advance() })
        case .howTo: HowToScreen(onNext: { advance() })
        case .tryIt: TryItScreen(onNext: { advance() }, latestRecord: latestRecord)
        case .done: DoneScreen(onFinish: onFinished)
        }
    }

    private func advance() {
        var next = Screen(rawValue: screen.rawValue + 1) ?? .done
        // Skip the Globe screen when the system action is already Do Nothing.
        if next == .globeKey, !FnUsageAdvisor.currentGlobeKeyAction().conflictsWithFnHotkey {
            next = .howTo
        }
        backStack.append(screen)
        screen = next
    }

    private func goBack() {
        guard let previous = backStack.popLast() else { return }
        screen = previous
    }

    private var progressDots: some View {
        HStack(spacing: JotUI.Spacing.xs) {
            ForEach(Screen.allCases, id: \.rawValue) { s in
                Circle()
                    .fill(s == screen ? JotUI.Colors.primary : JotUI.Colors.outlineVariant)
                    .frame(width: 6, height: 6)
            }
        }
    }
}

// MARK: - Shared pieces

private struct ScreenScaffold<Content: View>: View {
    let headline: String
    let body_: String
    let content: Content
    @Environment(\.colorScheme) private var scheme

    init(_ headline: String, _ body: String, @ViewBuilder content: () -> Content) {
        self.headline = headline
        self.body_ = body
        self.content = content()
    }

    var body: some View {
        VStack(spacing: JotUI.Spacing.l) {
            Text(headline)
                .font(JotUI.TypeScale.display(grad: scheme == .dark ? 25 : 0))
                .foregroundStyle(JotUI.Colors.onSurface)
                .multilineTextAlignment(.center)
            Text(body_)
                .font(JotUI.TypeScale.body(grad: scheme == .dark ? 25 : 0))
                .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            content
        }
    }
}

private struct PrimaryButton: View {
    let title: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(JotUI.TypeScale.title())
                // Disabled needs its OWN pair. Keeping onPrimary (a dark navy in
                // dark mode) over a grey container put dark text on a dark pill:
                // 1.37:1, effectively invisible — reported from the wild.
                // Material's 38% disabled label would only reach 2.8:1, and this
                // particular button is what a first-time user stares at while
                // they go and fetch their API key, so it is legible on purpose:
                // 4.2:1 dark / 3.4:1 light, still obviously inactive.
                .foregroundStyle(disabled ? JotUI.Colors.onSurface.opacity(0.55) : JotUI.Colors.onPrimary)
                .padding(.horizontal, JotUI.Spacing.xl)
                .padding(.vertical, JotUI.Spacing.s)
                .background(Capsule().fill(disabled
                    ? JotUI.Colors.onSurface.opacity(0.14)
                    : JotUI.Colors.primary))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

private struct PermissionCard: View {
    let icon: String
    let title: String
    let granted: Bool
    var actionTitle = JotL10n.text("Grant")
    let action: () -> Void

    var body: some View {
        HStack(spacing: JotUI.Spacing.s) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(granted ? JotUI.Colors.success : JotUI.Colors.primary)
                .frame(width: 28)
            Text(title)
                .font(JotUI.TypeScale.body())
                .foregroundStyle(JotUI.Colors.onSurface)
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(JotUI.Colors.success)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .padding(JotUI.Spacing.m)
        .background(RoundedRectangle(cornerRadius: JotUI.Radius.large).fill(JotUI.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: JotUI.Radius.large).strokeBorder(JotUI.Colors.outlineVariant.opacity(0.3), lineWidth: 1))
        .animation(JotMotion.expressiveFastSpatial, value: granted)
    }
}

// MARK: - Screens

private struct WelcomeScreen: View {
    let onNext: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var demoLevel: Float = 0
    @State private var heardShown = ""
    @State private var cleanShown = ""
    @State private var demoTask: Task<Void, Never>?

    // The whole promise in one loop: messy thought in, clean sentence out.
    private static let heardLine = JotL10n.text("привет проверяю голосовой ввод")
    private static let cleanLine = JotL10n.text("Привет! Проверяю голосовой ввод.")

    var body: some View {
        ScreenScaffold(JotL10n.text("Speak. It types."), JotL10n.text("Hold a key, say the thing, and polished text lands wherever your cursor is.")) {
            VStack(spacing: JotUI.Spacing.m) {
                WaveformView(level: demoLevel, processing: false)
                    .frame(width: 200, height: 48)
                    .background(Capsule().fill(JotUI.Colors.surface).shadow(color: .black.opacity(0.15), radius: 10, y: 2))
                demoText
                    .frame(width: 420, height: 48)
                PrimaryButton(title: JotL10n.text("Get started"), action: onNext)
            }
        }
        .onAppear(perform: startDemo)
        .onDisappear {
            demoTask?.cancel() // process-lifetime leak otherwise (audit L32)
            demoTask = nil
        }
    }

    @ViewBuilder
    private var demoText: some View {
        if reduceMotion {
            VStack(spacing: 2) {
                Text("“\(Self.heardLine)”")
                    .font(JotUI.TypeScale.labelSmall())
                    .italic()
                    .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                Text(Self.cleanLine)
                    .font(JotUI.TypeScale.body())
                    .foregroundStyle(JotUI.Colors.onSurface)
            }
        } else {
            VStack(spacing: 2) {
                Text(heardShown.isEmpty ? " " : "“\(heardShown)”")
                    .font(JotUI.TypeScale.labelSmall())
                    .italic()
                    .foregroundStyle(JotUI.Colors.onSurfaceVariant.opacity(cleanShown.isEmpty ? 1 : 0.45))
                Text(cleanShown.isEmpty ? " " : cleanShown)
                    .font(JotUI.TypeScale.body())
                    .foregroundStyle(JotUI.Colors.onSurface)
            }
            // The typewriter IS the animation — inherited implicit animations
            // crossfade every character and ghost the previous loop's text.
            .transaction { $0.animation = nil }
        }
    }

    private func startDemo() {
        guard !reduceMotion, demoTask == nil else { return }
        demoTask = Task { @MainActor in
            while !Task.isCancelled {
                heardShown = ""; cleanShown = ""
                // "Hearing": the messy line types in while the waveform speaks.
                for char in Self.heardLine {
                    guard !Task.isCancelled else { return }
                    heardShown.append(char)
                    demoLevel = Float.random(in: 0.35...0.8)
                    try? await Task.sleep(nanoseconds: 38_000_000)
                }
                demoLevel = 0.08
                try? await Task.sleep(nanoseconds: 450_000_000)
                // "Writing": the clean line lands, correction already applied.
                for char in Self.cleanLine {
                    guard !Task.isCancelled else { return }
                    cleanShown.append(char)
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                try? await Task.sleep(nanoseconds: 2_400_000_000)
            }
        }
    }
}

private struct APIKeyScreen: View {
    let onNext: () -> Void
    var body: some View {
        ScreenScaffold(JotL10n.text("Настройте распознавание речи"), JotL10n.text("Выберите провайдера, URL API и точное имя модели.")) {
            VStack(spacing: JotUI.Spacing.s) {
                Text(JotL10n.text("Выберите провайдера, укажите URL API, точное имя модели и её ключ. Очистку можно включить позже в настройках."))
                    .font(JotUI.TypeScale.body()).foregroundStyle(.secondary)
                APISettingsEditor(showCleanup: false)
                    .formStyle(.grouped)
                    .frame(height: 330)
                PrimaryButton(title: JotL10n.text("Продолжить"), action: onNext)
                Text(JotL10n.text("Можно настроить разрешения сейчас, а ключ добавить позже."))
                    .font(JotUI.TypeScale.labelSmall()).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MicScreen: View {
    let onNext: () -> Void
    @State private var granted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var level: Float = 0
    @State private var meter: AudioCaptureEngine?
    @State private var heard = false
    @State private var advancing = false
    @State private var speechFrames = 0
    /// Users reported setup picking the wrong input with no way to change it —
    /// the menu bar has had a Microphone submenu all along, but onboarding, the
    /// one place you are actually watching a level meter, did not.
    @State private var inputs: [AudioInputDevices.Device] = []
    @State private var selectedInput: AudioDeviceID?
    /// Counts level callbacks, NOT their value. A live mic in a silent room still
    /// ticks (with level ~0); a device that delivers nothing never ticks at all,
    /// which is the only way to tell "quiet" from "dead" from up here.
    @State private var meterTicks = 0
    @State private var deadDevice = false
    @State private var deadCheck: Timer?
    /// Loudest thing heard since this device was selected. A Bluetooth headset on
    /// the HFP path can be live but so quiet it never reaches the "heard you"
    /// threshold — indistinguishable, from the user's side, from a dead mic,
    /// because the waveform idles either way.
    @State private var maxLevel: Float = 0
    @State private var settled = false
    /// macOS asks ONCE per install. After a denial the prompt never reappears,
    /// so the button must stop pretending and send the user to System Settings.
    @State private var denied = AVCaptureDevice.authorizationStatus(for: .audio) == .denied
        || AVCaptureDevice.authorizationStatus(for: .audio) == .restricted

    // "Can we listen?" read as surveillance (dogfood). This screen is a mic
    // CHECK, so it behaves like one: say hello, Jot hears you, it moves on.
    private var headline: String {
        if granted { return JotL10n.text("Say hello.") }
        return denied ? JotL10n.text("The mic is switched off.") : JotL10n.text("Turn on the mic.")
    }
    private var sub: String {
        if heard { return JotL10n.text("Heard you loud and clear.") }
        if granted { return JotL10n.text("Jot is listening — this just checks your mic.") }
        return denied
            ? JotL10n.text("macOS only asks once. Turn Jot on under Privacy & Security → Microphone, then come back.")
            : JotL10n.text("macOS asks once. Jot only ever records while you're dictating.")
    }

    var body: some View {
        ScreenScaffold(headline, sub) {
            VStack(spacing: JotUI.Spacing.m) {
                if granted {
                    ZStack {
                        WaveformView(level: level, processing: false)
                            .opacity(heard ? 0 : 1)
                        if heard {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(JotUI.Colors.success)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .frame(width: 200, height: 48)
                    .background(Capsule().fill(JotUI.Colors.surface).shadow(color: .black.opacity(0.15), radius: 10, y: 2))
                    .animation(JotMotion.expressiveDefaultSpatial, value: heard)
        .animation(JotMotion.defaultEffects, value: maxLevel >= 0.06)
                    .onAppear(perform: startMeter)
                    .onDisappear(perform: stopMeter)
                    .onReceive(NotificationCenter.default.publisher(for: .onboardingWindowClosed)) { _ in
                        stopMeter() // window close bypasses onDisappear (audit #6)
                    }
                    // Always say what the mic is doing. The waveform breathes
                    // whether or not anything is arriving, so on its own it can
                    // never answer "is this working?".
                    if let status = micStatus {
                        Text(status.text)
                            .font(JotUI.TypeScale.labelSmall())
                            .foregroundStyle(status.bad ? JotUI.Colors.error : JotUI.Colors.onSurfaceVariant)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 340)
                            .transition(.opacity)
                    }
                    if inputs.count > 1 {
                        Picker("", selection: Binding(
                            get: { selectedInput ?? AudioInputDevices.currentDefaultID() },
                            set: { newValue in
                                guard let newValue, newValue != selectedInput else { return }
                                selectedInput = newValue
                                // Moves the SYSTEM default, exactly like the menu
                                // bar picker and Control Center — Jot always
                                // records from the default rather than pinning a
                                // device, which kills the tap on macOS 26.
                                AudioInputDevices.setDefault(id: newValue)
                                // Re-arm: the level meter is bound to whatever was
                                // open when it started, so a switch has to restart
                                // it or the user watches the OLD mic.
                                heard = false
                                speechFrames = 0
                                stopMeter()
                                startMeter()
                            }
                        )) {
                            ForEach(inputs) { device in
                                Text(device.name).tag(Optional(device.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 260)
                        .font(JotUI.TypeScale.labelSmall())
                    }

                    // Speaking IS the continue gesture; the quiet link remains for
                    // silent environments and users who can't speak.
                    Button(JotL10n.text("Continue without speaking")) { advance() }
                        .buttonStyle(.plain)
                        .font(JotUI.TypeScale.labelSmall())
                        .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                } else {
                    PermissionCard(
                        icon: "mic.fill",
                        title: JotL10n.text("Microphone"),
                        granted: granted,
                        actionTitle: denied ? JotL10n.text("Open Settings") : JotL10n.text("Grant")
                    ) {
                        if denied {
                            NSWorkspace.shared.open(URL(string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        } else {
                            AVCaptureDevice.requestAccess(for: .audio) { ok in
                                Task { @MainActor in
                                    granted = ok
                                    denied = !ok
                                }
                            }
                        }
                    }
                    // Never a dead end: setup continues, and the menu bar keeps
                    // saying what is still missing.
                    Button(JotL10n.text("Skip for now"), action: { advance() })
                        .buttonStyle(.plain)
                        .font(JotUI.TypeScale.labelSmall())
                        .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                }
            }
        }
        .onAppear {
            inputs = AudioInputDevices.list()
            selectedInput = AudioInputDevices.currentDefaultID()
        }
        .onReceive(NotificationCenter.default.publisher(for: .jotDefaultInputChanged).receive(on: RunLoop.main)) { _ in
            inputs = AudioInputDevices.list()
            selectedInput = AudioInputDevices.currentDefaultID()
        }
        .onChange(of: level) { _, value in
            // Sustained speech energy, not a door slam or chair scrape: ~150ms
            // above the speech threshold before it counts as "hello".
            guard !heard else { return }
            if value > 0.18 {
                speechFrames += 1
                if speechFrames >= 7 {
                    heard = true
                    advance(after: 0.9)
                }
            } else {
                speechFrames = max(0, speechFrames - 1)
            }
        }
    }

    private func advance(after delay: TimeInterval = 0) {
        guard !advancing else { return }
        advancing = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            stopMeter()
            onNext()
        }
    }

    /// What to tell the user about the input, in plain terms.
    private var micStatus: (text: String, bad: Bool)? {
        guard !heard else { return nil }
        let name = currentInputName ?? JotL10n.text("this input")
        if deadDevice {
            return (JotL10n.format("No sound is reaching Jot from %@. Pick a different input below.", String(describing: name)), true)
        }
        if maxLevel >= 0.06 {
            // Something is definitely arriving — say so, even before it is loud
            // enough to count as "hello".
            return (JotL10n.format("Picking up sound from %@ — keep going.", String(describing: name)), false)
        }
        if settled {
            return (JotL10n.format("Barely hearing anything from %@. Speak up, or pick a different input below.", String(describing: name)), true)
        }
        return (JotL10n.format("Listening on %@…", String(describing: name)), false)
    }

    private var currentInputName: String? {
        let id = selectedInput ?? AudioInputDevices.currentDefaultID()
        return inputs.first { $0.id == id }?.name
    }

    private func startMeter() {
        meterTicks = 0
        deadDevice = false
        maxLevel = 0
        settled = false
        deadCheck?.invalidate()
        // Bluetooth inputs can take a second or two to negotiate before the first
        // buffer lands, so this waits well past the built-in mic's ~270ms.
        deadCheck = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { _ in
            Task { @MainActor in
                if meterTicks == 0 { deadDevice = true }
                // Past this point "quiet" is a real observation, not just a mic
                // that has not warmed up yet.
                settled = true
                Log.ui.info("mic check on \(currentInputName ?? "?", privacy: .public): \(meterTicks) callbacks, peak \(maxLevel, format: .fixed(precision: 3))")
            }
        }
        let engine = AudioCaptureEngine()
        engine.onLevel = { value in
            Task { @MainActor in
                level = value
                meterTicks += 1
                maxLevel = max(maxLevel, value)
            }
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-mic-test.caf")
        try? engine.start(writingTo: scratch)
        meter = engine
    }

    private func stopMeter() {
        // Fire-and-forget: the meter's audio is a scratch file nobody reads, and
        // the screen must never wait on teardown.
        if let engine = meter {
            Task.detached(priority: .utility) { _ = await engine.stop() }
        }
        meter = nil
        deadCheck?.invalidate()
        deadCheck = nil
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-mic-test.caf"))
    }
}

private struct AccessibilityScreen: View {
    let onNext: () -> Void
    @State private var granted = AXIsProcessTrusted()
    @State private var pollTimer: Timer?
    @State private var slowGrant = false

    var body: some View {
        ScreenScaffold(JotL10n.text("Let it type for you."), JotL10n.text("macOS needs your OK before Jot can place text at your cursor.")) {
            VStack(spacing: JotUI.Spacing.m) {
                PermissionCard(icon: "keyboard", title: JotL10n.text("Accessibility"), granted: granted) {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                if slowGrant && !granted {
                    Text(JotL10n.text("Granted but not detected? A relaunch may be needed."))
                        .font(JotUI.TypeScale.labelSmall())
                        .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                }
                PrimaryButton(title: JotL10n.text("Continue"), disabled: !granted, action: onNext)
            }
        }
        .onAppear {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in
                    let trusted = AXIsProcessTrusted()
                    if trusted, !granted {
                        // Wake the engine NOW — otherwise the Try-It screen two
                        // steps later is dead until relaunch (production pass 2).
                        NotificationCenter.default.post(name: .gtSettingDidChange, object: "accessibility")
                        // They are standing in System Settings right now. Bring
                        // the flow back so the next step is in front of them
                        // rather than behind whatever they were just using.
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    granted = trusted
                }
            }
            Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { _ in
                Task { @MainActor in slowGrant = true }
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
        }
    }
}

private struct GlobeKeyScreen: View {
    let onNext: () -> Void
    @State private var fixed = !FnUsageAdvisor.currentGlobeKeyAction().conflictsWithFnHotkey
    @State private var pollTimer: Timer?

    var body: some View {
        ScreenScaffold(JotL10n.text("Make the 🌐 key yours."), JotL10n.text("macOS currently uses the Globe key for its own shortcut. One switch and it's your dictation key.")) {
            VStack(spacing: JotUI.Spacing.m) {
                VStack(alignment: .leading, spacing: JotUI.Spacing.xs) {
                    Text(JotL10n.text("In Keyboard settings, set:"))
                        .font(JotUI.TypeScale.labelSmall())
                        .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                    Text(JotL10n.text("Press 🌐 key to  →  Do Nothing"))
                        .font(JotUI.TypeScale.title())
                        .foregroundStyle(JotUI.Colors.onSurface)
                }
                .padding(JotUI.Spacing.m)
                .background(RoundedRectangle(cornerRadius: JotUI.Radius.large).fill(JotUI.Colors.surface))

                if fixed {
                    Label(JotL10n.text("Done — the Globe key is yours"), systemImage: "checkmark.circle.fill")
                        .font(JotUI.TypeScale.body())
                        .foregroundStyle(JotUI.Colors.success)
                } else {
                    Button(JotL10n.text("Open Keyboard Settings")) {
                        NSWorkspace.shared.open(FnUsageAdvisor.keyboardSettingsURL)
                    }
                    .buttonStyle(.bordered)
                }

                if FnUsageAdvisor.karabinerIsPresent() {
                    Text(JotL10n.text("Karabiner-Elements is running — if fn doesn't respond, add Jot to its exclusions."))
                        .font(JotUI.TypeScale.labelSmall())
                        .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                }

                PrimaryButton(title: fixed ? JotL10n.text("Continue") : JotL10n.text("Skip for now"), action: onNext)
            }
        }
        .onAppear {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in
                    fixed = !FnUsageAdvisor.currentGlobeKeyAction().conflictsWithFnHotkey
                }
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
        }
    }
}

/// Teach the product, not just prove it works (dogfood): the three gestures,
/// with the user's ACTUAL configured key, before the hands-on Try It.
private struct HowToScreen: View {
    let onNext: () -> Void
    private let keyName = SettingsStore().hotkeyKey.displayName

    var body: some View {
        ScreenScaffold(JotL10n.text("Talk to Jot."), JotL10n.text("Three gestures — that's the whole product.")) {
            VStack(spacing: JotUI.Spacing.m) {
                VStack(alignment: .leading, spacing: JotUI.Spacing.s) {
                    gestureRow(keys: [keyName], title: JotL10n.text("Hold and talk"),
                               detail: JotL10n.text("Release, and polished text lands at your cursor."))
                    gestureRow(keys: [keyName, "space"], title: JotL10n.text("Go hands-free"),
                               detail: JotL10n.format("Tap Space while holding — talk as long as you like, tap %@ to finish.", String(describing: keyName)))
                    gestureRow(keys: ["esc"], title: JotL10n.text("Changed your mind"),
                               detail: JotL10n.text("Cancels the dictation. Long recordings are kept in History."))
                }
                .padding(JotUI.Spacing.m)
                .background(RoundedRectangle(cornerRadius: JotUI.Radius.large).fill(JotUI.Colors.surface)
                    .shadow(color: .black.opacity(0.1), radius: 12, y: 2))
                PrimaryButton(title: JotL10n.text("Got it"), action: onNext)
            }
        }
    }

    private func gestureRow(keys: [String], title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: JotUI.Spacing.s) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    keycap(key)
                }
            }
            .frame(width: 132, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(JotUI.TypeScale.body())
                    .foregroundStyle(JotUI.Colors.onSurface)
                Text(detail)
                    .font(JotUI.TypeScale.labelSmall())
                    .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func keycap(_ label: String) -> some View {
        Text(label)
            .font(JotUI.TypeScale.code)
            .foregroundStyle(JotUI.Colors.onSurface)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(JotUI.Colors.surfaceContainer)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(JotUI.Colors.outlineVariant.opacity(0.6), lineWidth: 1))
            )
    }
}

private struct TryItScreen: View {
    let onNext: () -> Void
    var latestRecord: () -> DictationRecord? = { nil }
    @State private var text = ""
    @State private var celebrated = false
    @State private var revealRaw: String?
    @State private var revealClean: String?
    @State private var fetchTask: Task<Void, Never>?

    private let keyName = SettingsStore().hotkeyKey.displayName
    private var hasWords: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private static let script = JotL10n.text("Привет! Проверяю голосовой ввод.")

    var body: some View {
        ScreenScaffold(JotL10n.text("Try it."), JotL10n.text("Нажмите на поле, удерживайте ") + keyName + JotL10n.text(" и произнесите фразу:")) {
            VStack(spacing: JotUI.Spacing.s) {
                if revealRaw == nil {
                    Text("“\(Self.script)”")
                        .font(JotUI.TypeScale.body())
                        .italic()
                        .foregroundStyle(JotUI.Colors.onSurface)
                        .padding(.horizontal, JotUI.Spacing.m)
                        .padding(.vertical, JotUI.Spacing.xs)
                        .background(Capsule().fill(JotUI.Colors.surfaceContainer))
                    Text(JotL10n.text("(or say anything you like)"))
                        .font(JotUI.TypeScale.labelSmall())
                        .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(JotUI.TypeScale.bodyLarge())
                        .scrollContentBackground(.hidden)
                        .padding(JotUI.Spacing.s)
                        .frame(width: 400, height: 96)
                        .background(RoundedRectangle(cornerRadius: JotUI.Radius.large).fill(JotUI.Colors.surface))
                        .overlay(RoundedRectangle(cornerRadius: JotUI.Radius.large).strokeBorder(JotUI.Colors.outlineVariant.opacity(0.4), lineWidth: 1))
                    if text.isEmpty {
                        Text(JotL10n.text("Your words will land here."))
                            .font(JotUI.TypeScale.bodyLarge())
                            .foregroundStyle(JotUI.Colors.onSurfaceVariant.opacity(0.6))
                            .padding(JotUI.Spacing.m)
                            .allowsHitTesting(false)
                    }
                }
                if let raw = revealRaw, let clean = revealClean {
                    // The reveal: what the pipeline actually did to their words —
                    // real record data, shown only when a real difference exists.
                    // The two rows ARE the story — no caption needed.
                    VStack(alignment: .leading, spacing: 3) {
                        revealRow(label: JotL10n.text("You said"), value: raw, emphasized: false)
                        revealRow(label: JotL10n.text("Jot wrote"), value: clean, emphasized: true)
                    }
                    .padding(JotUI.Spacing.s)
                    .frame(width: 400, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: JotUI.Radius.medium).fill(JotUI.Colors.surfaceContainer))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if celebrated {
                    ConfettiBurst()
                        .frame(height: 40)
                    Text(JotL10n.format("You just dictated %@ words. That's the whole trick.", String(describing: text.split(separator: " ").count)))
                        .font(JotUI.TypeScale.body())
                        .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                }
                // Words in the field = the moment to move forward. Skipping is a
                // quiet option only while it's empty (dogfood: "Skip for now"
                // lingering after success wasn't helpful).
                if hasWords {
                    PrimaryButton(title: JotL10n.text("Continue"), action: onNext)
                } else {
                    Button(JotL10n.text("Skip for now"), action: onNext)
                        .buttonStyle(.plain)
                        .font(JotUI.TypeScale.body())
                        .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                        .padding(.vertical, JotUI.Spacing.s)
                }
            }
            .animation(JotMotion.expressiveDefaultSpatial, value: revealRaw)
        }
        .onChange(of: text) { _, newValue in
            if !celebrated, newValue.split(separator: " ").count >= 2 {
                celebrated = true
            }
            if hasWords, fetchTask == nil {
                fetchReveal()
            }
        }
        .onDisappear {
            fetchTask?.cancel()
            fetchTask = nil
        }
    }

    private func revealRow(label: String, value: String, emphasized: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: JotUI.Spacing.xs) {
            Text(label)
                .font(JotUI.TypeScale.labelSmall())
                .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                .frame(width: 62, alignment: .trailing)
            Text(value)
                .font(emphasized ? JotUI.TypeScale.body() : JotUI.TypeScale.labelSmall())
                .italic(!emphasized)
                .foregroundStyle(emphasized ? JotUI.Colors.onSurface : JotUI.Colors.onSurfaceVariant)
                .lineLimit(2)
        }
    }

    /// Show only the real ASR/cleanup difference, never a scripted reference.
    private func fetchReveal() {
        fetchTask = Task { @MainActor in
            for delay in [0.4, 1.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let record = latestRecord(),
                      let clean = record.cleanedTranscript, !clean.isEmpty else { continue }

                if let raw = record.rawTranscript, Self.normalized(raw) != Self.normalized(clean) {
                    revealRaw = raw
                    revealClean = clean
                    return
                }
            }
        }
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private struct DoneScreen: View {
    let onFinish: () -> Void
    // Default ON — consent by visibility; the finish handler reconciles against
    // the real SMAppService state, so unchecking on a re-run actually disables.
    @State private var launchAtLogin = true

    var body: some View {
        ScreenScaffold(JotL10n.text("You're set."), JotL10n.format("Jot lives in your menu bar now. Hold %@ anywhere and start talking.", String(describing: SettingsStore().hotkeyKey.displayName))) {
            VStack(spacing: JotUI.Spacing.m) {
                // Same voice as the scaffold's subtitle — two type sizes on the
                // page total (display + body), never three.
                // "strips your ums" read as jargon to a first-time user (Kat,
                // from the wild) — name the filler words plainly instead.
                Text(JotL10n.text("It removes filler words like \"umm\" and \"uhh\", follows your change of mind, and takes \"new paragraph\" literally. Teach it your jargon in Settings → Dictionary."))
                    .font(JotUI.TypeScale.body())
                    .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 480)
                Toggle(JotL10n.text("Start Jot at login"), isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                PrimaryButton(title: JotL10n.text("Start dictating")) {
                    let enabled = SMAppService.mainApp.status == .enabled
                    do {
                        if launchAtLogin, !enabled {
                            try SMAppService.mainApp.register()
                        } else if !launchAtLogin, enabled {
                            // Re-run onboarding + uncheck must actually disable it.
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        // Dev/translocated builds throw routinely — never block
                        // finishing onboarding on the login item.
                        Log.ui.error("onboarding launch-at-login failed: \(error)")
                    }
                    onFinish()
                }
            }
        }
    }
}

/// Four-color confetti — onboarding only (Reduce Motion gets a static card).
private struct ConfettiBurst: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        if reduceMotion {
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { i in
                    Circle().fill(JotUI.Colors.brandQuad[i]).frame(width: 8, height: 8)
                }
            }
        } else {
            GeometryReader { geo in
                ZStack {
                    ForEach(0..<24, id: \.self) { i in
                        Circle()
                            .fill(JotUI.Colors.brandQuad[i % 4])
                            .frame(width: 6, height: 6)
                            .offset(
                                x: animate ? CGFloat((i * 37) % 200) - 100 : 0,
                                y: animate ? CGFloat((i * 23) % 60) - 40 : 0
                            )
                            .opacity(animate ? 0 : 1)
                    }
                }
                .frame(maxWidth: .infinity)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .onAppear {
                withAnimation(.easeOut(duration: 1.2)) {
                    animate = true
                }
            }
        }
    }
}

import ServiceManagement
