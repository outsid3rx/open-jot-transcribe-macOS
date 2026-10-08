// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

public enum APIProvider: String, Codable, CaseIterable, Sendable {
    case gemini, polza, openAICompatible
    public var title: String {
        switch self {
        case .gemini: return "Google Gemini"
        case .polza: return "Polza"
        case .openAICompatible: return JotL10n.text("Совместимый API")
        }
    }
}

public enum RecognitionAPI: String, Codable, CaseIterable, Sendable {
    case gemini, geminiLegacy, audioTranscriptions, audioChat
    public var title: String {
        switch self {
        case .gemini: return "Gemini Interactions"
        case .geminiLegacy: return "Gemini Generate Content"
        case .audioTranscriptions: return JotL10n.text("Транскрибация файла")
        case .audioChat: return JotL10n.text("Чат с аудио")
        }
    }
}

/// An editable API base URL and an exact, unmodified provider model identifier.
/// Credentials are bound to the normalized base URL, never serialized here.
public struct ModelEndpoint: Codable, Equatable, Sendable {
    public var provider: APIProvider
    public var baseURL: String
    public var model: String
    public var recognitionAPI: RecognitionAPI

    public init(provider: APIProvider = .gemini,
                baseURL: String = "https://generativelanguage.googleapis.com",
                model: String = "gemini-3.5-transcribe", recognitionAPI: RecognitionAPI = .gemini) {
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.recognitionAPI = recognitionAPI
    }

    public static func preset(_ provider: APIProvider) -> Self {
        switch provider {
        case .gemini: return Self()
        case .polza:
            return Self(provider: .polza, baseURL: "https://polza.ai/api/v1",
                        model: "openai/gpt-4o-mini-transcribe", recognitionAPI: .audioTranscriptions)
        case .openAICompatible:
            return Self(provider: .openAICompatible, baseURL: "https://api.openai.com/v1",
                        model: "gpt-4o-mini-transcribe", recognitionAPI: .audioTranscriptions)
        }
    }

    public var url: URL? {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))))
        else { return nil }
        return components.url
    }

    public var credentialAccount: String {
        let normalized = url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            ?? baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == .gemini, normalized == "https://generativelanguage.googleapis.com" {
            return "gemini-api-key" // Keep the existing Keychain item.
        }
        let digest = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        return "api-\(provider.rawValue)-\(digest)"
    }

    public func validate() throws {
        guard url != nil else { throw TranscriptionError.badRequest(JotL10n.text("Укажите корректный HTTPS URL API (HTTP разрешён только для localhost).")) }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionError.badRequest(JotL10n.text("Укажите идентификатор модели у провайдера."))
        }
        guard model.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw TranscriptionError.badRequest(JotL10n.text("Название модели должно быть одной строкой."))
        }
    }
}

/// Persisted with each recording. Switching Settings cannot reroute a retry.
public struct TranscriptionConfiguration: Codable, Equatable, Sendable {
    public var recognition: ModelEndpoint
    public var cleanup: ModelEndpoint
    public var cleanupUsesRecognitionAPI: Bool
    public var cleanupEnabled: Bool
    public var language: String
    public var nativeSmart: Bool
    public var matchTone: Bool

    public init(recognition: ModelEndpoint = ModelEndpoint(),
                cleanup: ModelEndpoint = ModelEndpoint(model: "gemini-3.5-flash-lite"),
                cleanupUsesRecognitionAPI: Bool = true, cleanupEnabled: Bool = false,
                language: String = "", nativeSmart: Bool = true, matchTone: Bool = false) {
        self.recognition = recognition
        self.cleanup = cleanup
        self.cleanupUsesRecognitionAPI = cleanupUsesRecognitionAPI
        self.cleanupEnabled = cleanupEnabled
        self.language = language
        self.nativeSmart = nativeSmart
        self.matchTone = matchTone
    }

    public var effectiveCleanup: ModelEndpoint {
        guard cleanupUsesRecognitionAPI else { return cleanup }
        var endpoint = recognition
        endpoint.model = cleanup.model
        return endpoint
    }

    public var explicitLanguage: String? {
        let value = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty || value == "auto" ? nil : value
    }

    public var permitsLive: Bool {
        recognition.provider == .gemini && recognition.recognitionAPI == .gemini
            && recognition.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "https://generativelanguage.googleapis.com"
            && recognition.model == "gemini-3.5-transcribe" && explicitLanguage == nil && !cleanupEnabled
    }
}
