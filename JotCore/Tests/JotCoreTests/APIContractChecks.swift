// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation
@testable import JotCore

// Shared by XCTest and scripts/verify-api-contract.sh (works with Command Line Tools).
// All URLs and keys are synthetic; the URLProtocol prevents real network requests.
enum APIContractChecks {
    struct Failed: Error, CustomStringConvertible { let description: String }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failed(description: message) }
    }

    @MainActor static func run() async throws -> [String] {
        let suite = "JotAPIContract-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousRoot = FileLayout.overrideRoot
        FileLayout.overrideRoot = root
        defer {
            FileLayout.overrideRoot = previousRoot
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let settings = SettingsStore(defaults: defaults)
        let dictionary = DictionaryStore(defaults: defaults)
        let recorder = RequestRecorder()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ContractURLProtocol.self]
        ContractURLProtocol.recorder = recorder
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let client = CompatibleAPIClient(apiKey: { "synthetic-key" }, session: session)
        let service = TranscriptionService(settings: settings, apiKey: { _ in "synthetic-key" }, session: session, dictionary: dictionary)
        var passed = [String]()
        func pass(_ name: String) { passed.append(name) }

        var endpoint = ModelEndpoint.preset(.polza)
        try require(endpoint.url?.absoluteString == "https://polza.ai/api/v1", "Polza base URL")
        let originalAccount = endpoint.credentialAccount
        endpoint.baseURL += "/"
        try require(endpoint.credentialAccount == originalAccount, "Trailing slash must preserve credential binding")
        endpoint.baseURL = "https://other.invalid/v1"
        try require(endpoint.credentialAccount != originalAccount, "Different origin must require its own key")
        for url in ["https://key@example.invalid/v1", "https://example.invalid/v1?key=x", "ftp://example.invalid", "http://example.invalid", "https://"] {
            endpoint.baseURL = url
            try require(endpoint.url == nil, "Unsafe URL accepted: \(url)")
        }
        for url in ["http://localhost:8080/v1", "http://127.0.0.1:8080/v1", "http://[::1]:8080/v1"] {
            endpoint.baseURL = url
            try require(endpoint.url != nil, "Localhost rejected: \(url)")
        }
        pass("URL validation and credential origin binding")

        let guardDelegate = CredentialRedirectGuard()
        let task = session.dataTask(with: URL(string: "https://asr.invalid/v1")!)
        let redirectResponse = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for url in ["https://other.invalid/v1", "http://asr.invalid/v1", "https://asr.invalid:8443/v1"] {
            var accepted = true
            guardDelegate.urlSession(session, task: task, willPerformHTTPRedirection: redirectResponse,
                                     newRequest: URLRequest(url: URL(string: url)!)) { accepted = $0 != nil }
            try require(!accepted, "Credential redirect accepted: \(url)")
        }
        task.cancel()
        pass("Reject cross-origin and downgraded credential redirects")

        endpoint = ModelEndpoint.preset(.openAICompatible)
        endpoint.baseURL = "https://asr.invalid/api/v1"
        endpoint.model = "vendor/exact-model-v1"
        recorder.reset(responses: [.text("Привет!")])
        _ = try await client.transcribe(audio: Data([1, 2, 3]), endpoint: endpoint, language: "ru", vocabulary: [], duration: 1, deadline: 2)
        let request = recorder.requests[0]
        let body = String(decoding: recorder.bodies[0], as: UTF8.self)
        try require(request.url?.path == "/api/v1/audio/transcriptions", "Wrong ASR path")
        try require(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-key", "Missing Bearer header")
        try require(body.contains("vendor/exact-model-v1") && body.contains("name=\"language\"\r\n\r\nru\r\n"), "Manual model ID/language lost")
        try require(body.contains("filename=\"audio.wav\"") && body.contains("Content-Type: audio/wav"), "WAV multipart contract")
        pass("Multipart WAV, exact model ID and Russian language")

        recorder.reset(responses: [.text("Hello")])
        _ = try await client.transcribe(audio: Data(), endpoint: endpoint, language: nil, vocabulary: [], duration: 1, deadline: 2)
        try require(!String(decoding: recorder.bodies[0], as: UTF8.self).contains("name=\"language\""), "Auto must omit language")
        pass("Automatic language omission")

        endpoint.recognitionAPI = .audioChat
        recorder.reset(responses: [.chat("Расшифровка")])
        _ = try await client.transcribe(audio: Data([1, 2]), endpoint: endpoint, language: "ru", vocabulary: ["VibeBoard"], duration: 1, deadline: 2)
        let chat = try JSONSerialization.jsonObject(with: recorder.bodies[0]) as! [String: Any]
        let messages = chat["messages"] as! [[String: Any]]
        let parts = messages[0]["content"] as! [[String: Any]]
        let audio = parts[0]["input_audio"] as! [String: Any]
        try require(recorder.requests[0].url?.path == "/api/v1/chat/completions", "Wrong audio chat path")
        try require(audio["format"] as? String == "wav" && audio["data"] as? String == Data([1,2]).base64EncodedString(), "Audio chat envelope")
        try require(chat["model"] as? String == endpoint.model, "Audio chat model rewritten")
        pass("Standard audio-chat envelope (no live-provider claim)")
        endpoint.recognitionAPI = .audioTranscriptions

        for (status, expected) in [(401, TranscriptionError.auth), (402, .insufficientBalance), (429, .rateLimitedTransient), (503, .network("http_503"))] {
            recorder.reset(responses: [.init(status: status, body: Data())])
            do {
                _ = try await client.transcribe(audio: Data(), endpoint: endpoint, language: nil, vocabulary: [], duration: 1, deadline: 2)
                throw Failed(description: "HTTP \(status) incorrectly succeeded")
            } catch let error as TranscriptionError { try require(error == expected, "Wrong HTTP \(status) mapping") }
        }
        recorder.reset(responses: [.init(status: 429, body: Data(), headers: ["Retry-After": "0"]), .text("Повтор")])
        _ = try await client.transcribe(audio: Data(), endpoint: endpoint, language: nil, vocabulary: [], duration: 1, deadline: 2)
        try require(recorder.requests.count == 2, "Retry-After should retry once")
        pass("Authentication, balance, rate limits, server errors and bounded retry")

        recorder.reset(responses: [.chat("Обрезанный текст", finishReason: "length")])
        do {
            _ = try await client.cleanup(prompt: "Test", endpoint: endpoint, deadline: 2)
            throw Failed(description: "Truncated chat accepted")
        } catch TranscriptionError.badRequest { }
        pass("Reject truncated model output")

        var config = TranscriptionConfiguration(recognition: endpoint)
        try require(!config.cleanupEnabled, "Cleanup must default OFF")
        try require(config.cleanupTimeoutSeconds == 10, "Cleanup timeout must default to 10 seconds")
        var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as! [String: Any]
        oldJSON.removeValue(forKey: "cleanupTimeoutSeconds")
        let oldConfigData = try JSONSerialization.data(withJSONObject: oldJSON)
        defaults.set(oldConfigData, forKey: "transcriptionConfiguration")
        try require(settings.transcriptionConfiguration == config, "Old settings lost provider/model or failed to default timeout")
        config.cleanupTimeoutSeconds = 37
        settings.setTranscriptionConfiguration(config)
        try require(settings.transcriptionConfiguration == config, "Custom cleanup timeout did not persist")
        oldJSON["cleanupTimeoutSeconds"] = -1
        let lowerBound = try JSONDecoder().decode(TranscriptionConfiguration.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        oldJSON["cleanupTimeoutSeconds"] = 999
        let upperBound = try JSONDecoder().decode(TranscriptionConfiguration.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        try require(lowerBound.cleanupTimeoutSeconds == 1 && upperBound.cleanupTimeoutSeconds == 120, "Timeout bounds were not enforced")
        config.cleanupTimeoutSeconds = 10
        pass("Default/custom cleanup timeout, saved settings migration and bounds")
        let neverRequest = TranscriptionService(settings: settings, apiKey: { _ in fatalError("Cleanup OFF must not read a key") }, session: session, dictionary: dictionary)
        recorder.reset(responses: [])
        let unchanged = try await neverRequest.clean("Тест без очистки.", configuration: config, context: DictationContext())
        try require(unchanged == "Тест без очистки." && recorder.requests.isEmpty, "Cleanup OFF did work")
        pass("Cleanup OFF: zero requests and zero key lookups")

        config.cleanupEnabled = true
        config.cleanupUsesRecognitionAPI = false
        config.cleanup = ModelEndpoint(provider: .openAICompatible, baseURL: "https://cleanup.invalid/v1", model: "text/cheap-model", recognitionAPI: .audioTranscriptions)
        recorder.reset(responses: [.chat("Давайте завтра в 4.")])
        let clean = try await service.clean("Эм, давайте завтра в три, нет лучше в четыре.", configuration: config, context: DictationContext())
        try require(clean == "Давайте завтра в 4.", "Russian self-correction rejected")
        let cleanupBody = try JSONSerialization.jsonObject(with: recorder.bodies[0]) as! [String: Any]
        try require(recorder.requests[0].url?.host == "cleanup.invalid" && cleanupBody["model"] as? String == "text/cheap-model", "Separate cleanup URL/model lost")
        pass("Independent cleanup API/model and Russian self-correction")

        recorder.reset(responses: [.chat("Купите молоко и хлеб.", delay: 2)])
        let delayedCleanup = try await service.clean("Эм, купите молоко и хлеб.", configuration: config, context: DictationContext())
        try require(delayedCleanup == "Купите молоко и хлеб.", "Default budget still discarded a response after 1.5 seconds")
        try require(recorder.requests[0].timeoutInterval == 10, "Configured timeout did not reach the API client")
        pass("Default 10-second budget accepts delayed cleanup")

        for response in [ContractResponse.chat("Конечно, вот ответ: я напишу совершенно другую историю."), .init(status: 401, body: Data())] {
            recorder.reset(responses: [response])
            let fallback = try await service.clean("Купите молоко и хлеб.", configuration: config, context: DictationContext())
            try require(fallback == "Купите молоко и хлеб.", "Cleanup failure lost original words")
        }
        recorder.reset(responses: [.init(status: 200, body: Data(), neverFinish: true)])
        config.cleanupTimeoutSeconds = 1
        let timeoutStart = Date()
        let fallback = try await service.clean("Купите молоко и хлеб.", configuration: config, context: DictationContext())
        try require(fallback == "Купите молоко и хлеб.", "Cleanup deadline lost words")
        try require(Date().timeIntervalSince(timeoutStart) < 2.5, "Custom cleanup timeout was ignored")
        pass("Cleanup answer/error/deadline fallback preserves ASR")

        recorder.reset(responses: [.init(status: 429, body: Data(), headers: ["Retry-After": "8"]), .chat("Купите молоко и хлеб.")])
        let retryStart = Date()
        let retryFallback = try await service.clean("Эм, купите молоко и хлеб.", configuration: config, context: DictationContext())
        try require(retryFallback == "Эм, купите молоко и хлеб.", "Expired retry wait lost ASR")
        try require(Date().timeIntervalSince(retryStart) < 2.5 && recorder.requests.count == 1, "429 wait escaped the total cleanup budget")
        pass("Cleanup budget includes 429 wait and prevents a late retry")

        recorder.reset(responses: [.init(status: 200, body: Data(), neverFinish: true)])
        let cancelledCleanup = Task { try await service.clean("Купите молоко и хлеб.", configuration: config, context: DictationContext()) }
        try await Task.sleep(nanoseconds: 50_000_000)
        cancelledCleanup.cancel()
        do {
            _ = try await cancelledCleanup.value
            throw Failed(description: "Cancelled cleanup returned fallback instead of cancellation")
        } catch is CancellationError { }
        pass("User cancellation propagates through the total cleanup budget")
        config.cleanupTimeoutSeconds = 3

        recorder.reset(responses: [.init(status: 200, body: Data(), neverFinish: true)])
        let cancelled = Task { try await client.transcribe(audio: Data(), endpoint: endpoint, language: nil, vocabulary: [], duration: 1, deadline: 5) }
        try await Task.sleep(nanoseconds: 50_000_000)
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw Failed(description: "Cancelled request returned success")
        } catch is CancellationError { }
        pass("Cancellation stops an in-flight request")

        let wavURL = root.appendingPathComponent("fixture.wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        do {
            let writer = try AVAudioFile(forWriting: wavURL, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            memset(buffer.int16ChannelData![0], 0, 32_000)
            try writer.write(from: buffer)
        }
        let callback = LockedFlag()
        recorder.reset(responses: [.text("Список: молоко, хлеб, яйца."), .chat("Список:\n- Молоко\n- Хлеб\n- Яйца")])
        recorder.onRequest = { req in
            if req.url?.host == "cleanup.invalid" { precondition(callback.value, "Raw callback must precede cleanup") }
        }
        config.language = "ru"
        let result = try await service.transcribe(audioURL: wavURL, durationSeconds: 1, context: DictationContext(configuration: config), onRawTranscript: { raw in
            precondition(raw == "Список: молоко, хлеб, яйца.")
            callback.set()
        })
        try require(result.rawTranscript == "Список: молоко, хлеб, яйца." && result.cleanedTranscript.contains("- Яйца"), "Two-pass output")
        try require(String(decoding: recorder.bodies[0].prefix(400), as: UTF8.self).contains("language"), "Pipeline lost language")
        pass("End-to-end local WAV conversion, ASR callback before cleanup and lists")
        recorder.onRequest = nil

        let history = try HistoryStore(databaseURL: root.appendingPathComponent("history.sqlite"))
        var meta = SessionMeta(id: UUID(), startedAt: Date(), status: .queuedForRetry)
        meta.configuration = config
        let folder = try FileLayout.makeSessionFolder(id: meta.id)
        try FileManager.default.copyItem(at: wavURL, to: FileLayout.audioCAF(in: folder))
        meta.write(to: folder)
        history.upsert(meta: meta, folder: folder)
        var newConfig = TranscriptionConfiguration(recognition: ModelEndpoint(provider: .openAICompatible, baseURL: "https://new.invalid/v1", model: "new/manual-model", recognitionAPI: .audioTranscriptions))
        newConfig.language = "en"
        settings.setTranscriptionConfiguration(newConfig)
        let spy = ContextSpy()
        let retry = RetryQueue(store: history, transcription: spy, settings: settings)
        _ = await retry.retrySingle(DictationRecord(meta: meta, folder: folder))
        try require(spy.configurations[0] == config, "Retry silently rerouted old audio")
        let row = history.records().first!
        try require(row.apiBaseURL == endpoint.baseURL && row.modelID == endpoint.model && row.language == "ru", "History metadata index")
        _ = await retry.retrySingle(row, useCurrentConfiguration: true)
        try require(spy.configurations[1] == newConfig && history.records().count == 2, "Explicit reprocessing must create a new row with current configuration")
        try require(SessionMeta.read(from: folder)?.configuration == config, "Explicit reprocessing mutated old record")
        pass("Snapshot retry, SQL metadata migration and explicit reprocessing")

        let legacyData = Data("{\"id\":\"\(UUID().uuidString)\",\"startedAt\":\"2026-10-08T12:00:00Z\",\"status\":\"queuedForRetry\",\"gapMarkers\":[]}".utf8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(SessionMeta.self, from: legacyData)
        try require(legacy.configuration == nil, "Old history must decode without new fields")
        let oldMetaData = try JSONEncoder().encode(meta)
        var oldMetaJSON = try JSONSerialization.jsonObject(with: oldMetaData) as! [String: Any]
        var oldSnapshot = oldMetaJSON["configuration"] as! [String: Any]
        oldSnapshot.removeValue(forKey: "cleanupTimeoutSeconds")
        oldMetaJSON["configuration"] = oldSnapshot
        let oldMeta = try JSONDecoder().decode(SessionMeta.self, from: JSONSerialization.data(withJSONObject: oldMetaJSON))
        var expectedOldConfig = config
        expectedOldConfig.cleanupTimeoutSeconds = 10
        try require(oldMeta.configuration == expectedOldConfig, "Old history snapshot lost configuration during timeout migration")
        settings.migrateAPISettings()
        let baseline = settings.legacyTranscriptionConfiguration
        settings.setTranscriptionConfiguration(config)
        try require(settings.legacyTranscriptionConfiguration == baseline, "Legacy baseline must stay immutable")
        pass("Backward-compatible metadata and immutable legacy migration")

        // Capture starts on the next runloop turn. A settings edit during warming
        // must not activate Google Live for a session that began on a compatible API.
        var selected = config
        let capture = ContractCapture()
        let coordinator = DictationCoordinator(
            audioFactory: { capture }, transcription: spy, insertion: ContractInserter(),
            contextProvider: { DictationContext(configuration: selected) },
            noiseHandlingEnabled: { false }, secureInputActive: { false },
            makeLiveSession: { _ in fatalError("Compatible API snapshot must never create Google Live") }
        )
        coordinator.handle(.begin)
        let capturedFolder = coordinator.activeSessionFolder!
        selected = TranscriptionConfiguration()
        for _ in 0..<20 where !capture.started { await Task.yield() }
        try require(capture.started && SessionMeta.read(from: capturedFolder)?.configuration == config, "Warming lost API snapshot")
        coordinator.handle(.cancel)
        try await Task.sleep(nanoseconds: 50_000_000)
        pass("Coordinator snapshots API before warming and excludes Google Live for compatible APIs")

        // Account-level failure must not block a different provider in the queue.
        for (offset, cfg) in [config, config, newConfig].enumerated() {
            var queued = SessionMeta(id: UUID(), startedAt: Date().addingTimeInterval(Double(offset)), status: .failed)
            queued.configuration = cfg; queued.errorCode = "auth"
            let queuedFolder = try FileLayout.makeSessionFolder(id: queued.id)
            try FileManager.default.copyItem(at: wavURL, to: FileLayout.audioCAF(in: queuedFolder))
            queued.write(to: queuedFolder); history.upsert(meta: queued, folder: queuedFolder)
        }
        let blockedSpy = ContextSpy(blockedHost: "asr.invalid")
        let blockedQueue = RetryQueue(store: history, transcription: blockedSpy, settings: settings)
        await blockedQueue.drain()
        try require(blockedSpy.configurations.count == 2 && blockedSpy.configurations[1]?.recognition.url?.host == "new.invalid", "One blocked profile stalled another provider or retried siblings")
        pass("Blocked credential profile isolation and retry after key changes")

        try require(ValidationGate.validate(raw: "Можно ли перенести встречу на пятницу?", cleaned: "Конечно, встречу можно перенести на пятницу.").accepted == false, "Russian assistant answer not rejected")
        try require(ValidationGate.validate(raw: "Конечно, купите молоко и хлеб.", cleaned: "Конечно, купите молоко и хлеб.").accepted, "Speaker opener falsely rejected")
        try require(JotL10n.text("History", language: .russian) == "История", "Russian bundle not loaded")
        try require(JotL10n.wordCount(1, language: .russian) == "1 слово" && JotL10n.wordCount(22, language: .russian) == "22 слова" && JotL10n.wordCount(14, language: .russian) == "14 слов", "Russian plurals")
        pass("Russian fidelity checks, localization bundle and plurals")

        try require(settings.interfaceLanguage == .russian, "Interface language must default to Russian")
        let savedTranscription = settings.transcriptionConfiguration
        settings.setInterfaceLanguage(.english)
        try require(SettingsStore(defaults: defaults).interfaceLanguage == .english, "Interface language did not persist")
        try require(settings.transcriptionConfiguration == savedTranscription, "Interface language changed speech settings")
        try require(JotL10n.text("API и модели", language: .english) == "API and models", "New API settings not translated")
        try require(JotL10n.text("Время ожидания очистки", language: .english) == "Cleanup timeout", "Timeout setting not translated")
        try require(JotL10n.text("History", language: .english) == "History", "Original English copy not restored")
        try require(JotL10n.wordCount(1, language: .english) == "1 word" && JotL10n.wordCount(22, language: .english) == "22 words", "English plurals")
        pass("Russian default, saved English choice, bilingual resources and independent speech language")
        return passed
    }
}

private struct ContractResponse {
    var status: Int
    var body: Data
    var headers: [String: String] = [:]
    var neverFinish = false
    var delay: TimeInterval = 0
    static func text(_ text: String) -> Self { Self(status: 200, body: try! JSONSerialization.data(withJSONObject: ["text": text])) }
    static func chat(_ text: String, finishReason: String = "stop", delay: TimeInterval = 0) -> Self {
        Self(status: 200, body: try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": finishReason, "message": ["content": text]]]]), delay: delay)
    }
}
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock(); private var stored = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
    func set() { lock.lock(); stored = true; lock.unlock() }
}
private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = [ContractResponse]()
    private var storedRequests = [URLRequest]()
    private var storedBodies = [Data]()
    var onRequest: ((URLRequest) -> Void)?
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return storedRequests }
    var bodies: [Data] { lock.lock(); defer { lock.unlock() }; return storedBodies }
    func reset(responses: [ContractResponse]) {
        lock.lock(); defer { lock.unlock() }; pending = responses; storedRequests = []; storedBodies = []
    }
    func respond(_ request: URLRequest) -> ContractResponse {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
            }
        }
        lock.lock()
        storedRequests.append(request); storedBodies.append(body)
        let response = pending.isEmpty ? ContractResponse(status: 500, body: Data()) : pending.removeFirst()
        lock.unlock()
        onRequest?(request)
        return response
    }
}
private final class ContractURLProtocol: URLProtocol {
    static var recorder: RequestRecorder!
    private var responseWork: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = Self.recorder.respond(request)
        if response.neverFinish { return }
        if response.delay > 0 {
            let work = DispatchWorkItem { [weak self] in self?.finish(response) }
            responseWork = work
            DispatchQueue.global().asyncAfter(deadline: .now() + response.delay, execute: work)
        } else {
            finish(response)
        }
    }
    private func finish(_ response: ContractResponse) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: response.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { responseWork?.cancel() }
}
@MainActor private final class ContextSpy: TranscriptionServicing {
    var configurations = [TranscriptionConfiguration?]()
    let blockedHost: String?
    init(blockedHost: String? = nil) { self.blockedHost = blockedHost }
    func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
        configurations.append(context.configuration)
        if context.configuration?.recognition.url?.host == blockedHost { throw TranscriptionError.auth }
        return TranscriptionResult(rawTranscript: "Сохранённый текст", cleanedTranscript: "Сохранённый текст", modelID: context.configuration!.recognition.model)
    }
}

private final class ContractCapture: AudioCapturing {
    var onLevel: ((Float) -> Void)?
    var onDeviceChange: ((String) -> Void)?
    var onWriteFailure: (() -> Void)?
    var onEngineDied: ((String) -> Void)?
    var started = false
    func start(writingTo url: URL, pcmSink: (@Sendable (Data) -> Void)?) throws {
        precondition(pcmSink == nil)
        started = true
    }
    func stop() async -> AudioCaptureResult { AudioCaptureResult(framesWritten: 0, durationSeconds: 0) }
}
private final class ContractInserter: TextInserting {
    @MainActor func insert(_ text: String, context: DictationContext) async -> InsertionOutcome { .inserted }
}
