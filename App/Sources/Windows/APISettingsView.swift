// SPDX-License-Identifier: Apache-2.0

import JotCore
import SwiftUI

/// Manual fields are authoritative; provider presets only supply editable defaults.
struct APISettingsEditor: View {
    var showCleanup = true
    @State private var configuration = SettingsStore().transcriptionConfiguration
    private let settings = SettingsStore()

    var body: some View {
        Form {
            Section(JotL10n.text("Распознавание речи")) {
                EndpointFields(endpoint: $configuration.recognition)
                Picker(JotL10n.text("Язык транскрибации"), selection: $configuration.language) {
                    Text(JotL10n.text("Автоматически")).tag("")
                    Text(JotL10n.text("Русский")).tag("ru")
                    Text(JotL10n.text("Английский")).tag("en")
                    Text(JotL10n.text("Немецкий")).tag("de")
                    Text(JotL10n.text("Французский")).tag("fr")
                    Text(JotL10n.text("Испанский")).tag("es")
                    if !["", "ru", "en", "de", "fr", "es"].contains(configuration.language) {
                        Text(configuration.language).tag(configuration.language)
                    }
                }
                .disabled(configuration.recognition.provider == .gemini)
                if configuration.recognition.provider != .gemini {
                    TextField(JotL10n.text("Код языка (ISO 639-1)"), text: $configuration.language, prompt: Text(JotL10n.text("Пусто — автоматически")))
                } else {
                    Text(JotL10n.text("Gemini использует автоматическое определение языка. Для явного языка выберите API транскрибации файла."))
                        .font(JotUI.TypeScale.labelSmall()).foregroundStyle(.secondary)
                }
                APIKeyEditor(endpoint: configuration.recognition)
            }
            if showCleanup {
                Section {
                    Toggle(JotL10n.text("Очищать и оформлять текст"), isOn: $configuration.cleanupEnabled)
                    Text(JotL10n.text("Удаляет слова-паразиты, применяет самокоррекции и оформляет списки. Выполняет дополнительный платный запрос с текстом. По умолчанию выключено."))
                        .font(JotUI.TypeScale.labelSmall()).foregroundStyle(.secondary)
                    if configuration.cleanupEnabled {
                        Toggle(JotL10n.text("Использовать тот же API"), isOn: $configuration.cleanupUsesRecognitionAPI)
                        if configuration.cleanupUsesRecognitionAPI {
                            TextField(JotL10n.text("Модель очистки"), text: $configuration.cleanup.model,
                                      prompt: Text(cleanupExample(configuration.recognition.provider)))
                                .font(JotUI.TypeScale.code)
                            Text(JotL10n.text("URL и ключ берутся из настроек распознавания. Модель должна поддерживать текстовый чат."))
                                .font(JotUI.TypeScale.labelSmall()).foregroundStyle(.secondary)
                        } else {
                            EndpointFields(endpoint: $configuration.cleanup, isCleanup: true)
                            APIKeyEditor(endpoint: configuration.cleanup)
                        }
                        Toggle(JotL10n.text("Подстраивать тон под приложение"), isOn: $configuration.matchTone)
                    }
                } header: { Text(JotL10n.text("Очистка текста")) }
            }
        }
        .onChange(of: configuration) { _, value in
            if value != settings.transcriptionConfiguration { settings.setTranscriptionConfiguration(value) }
        }
        .onChange(of: configuration.recognition.provider) { _, provider in
            configuration.cleanupEnabled = false
            if configuration.cleanupUsesRecognitionAPI { configuration.cleanup.model = cleanupExample(provider) }
            if provider == .gemini { configuration.language = "" }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange)) { note in
            if note.object as? String == "transcriptionConfiguration" {
                let saved = settings.transcriptionConfiguration
                if saved != configuration { configuration = saved }
            }
        }
    }

    private func cleanupExample(_ provider: APIProvider) -> String {
        switch provider {
        case .gemini: return "gemini-3.5-flash-lite"
        case .polza: return "google/gemini-2.5-flash-lite"
        case .openAICompatible: return "gpt-4o-mini"
        }
    }
}

private struct EndpointFields: View {
    @Binding var endpoint: ModelEndpoint
    var isCleanup = false

    var body: some View {
        Picker(JotL10n.text("Провайдер"), selection: Binding(get: { endpoint.provider }, set: { provider in
            endpoint = ModelEndpoint.preset(provider)
            if isCleanup {
                switch provider {
                case .gemini: endpoint.model = "gemini-3.5-flash-lite"
                case .polza: endpoint.model = "google/gemini-2.5-flash-lite"
                case .openAICompatible: endpoint.model = "gpt-4o-mini"
                }
            }
        })) {
            ForEach(APIProvider.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        TextField(JotL10n.text("Базовый URL API"), text: $endpoint.baseURL,
                  prompt: Text(ModelEndpoint.preset(endpoint.provider).baseURL))
            .font(JotUI.TypeScale.code)
        TextField(isCleanup ? JotL10n.text("Модель очистки") : JotL10n.text("Модель транскрибации"), text: $endpoint.model,
                  prompt: Text(JotL10n.text("Точный идентификатор у провайдера")))
            .font(JotUI.TypeScale.code)
        if endpoint.url == nil {
            Text(JotL10n.text("Укажите HTTPS URL без ключа и параметров запроса. HTTP разрешён для localhost."))
                .font(JotUI.TypeScale.labelSmall()).foregroundStyle(JotUI.Colors.error)
        }
        if !isCleanup {
            Picker(JotL10n.text("Тип API распознавания"), selection: $endpoint.recognitionAPI) {
                if endpoint.provider == .gemini {
                    Text(RecognitionAPI.gemini.title).tag(RecognitionAPI.gemini)
                    Text(RecognitionAPI.geminiLegacy.title).tag(RecognitionAPI.geminiLegacy)
                } else {
                    Text(RecognitionAPI.audioTranscriptions.title).tag(RecognitionAPI.audioTranscriptions)
                    Text(RecognitionAPI.audioChat.title).tag(RecognitionAPI.audioChat)
                }
            }
            if endpoint.recognitionAPI == .audioChat {
                Text(JotL10n.text("Для моделей с аудиовходом через chat/completions. Такая модель может ответить вместо расшифровки; контракт конкретного провайдера необходимо проверить."))
                    .font(JotUI.TypeScale.labelSmall()).foregroundStyle(.secondary)
            }
        }
        Text(JotL10n.text("URL и модель можно вводить вручную. Названия моделей передаются провайдеру без замены."))
            .font(JotUI.TypeScale.labelSmall()).foregroundStyle(.secondary)
    }
}

private struct APIKeyEditor: View {
    let endpoint: ModelEndpoint
    @State private var draft = ""
    @State private var hasKey = false
    @State private var message = ""

    var body: some View {
        SecureField(JotL10n.text("Ключ API"), text: $draft, prompt: Text(hasKey ? JotL10n.text("Ключ сохранён в Keychain") : JotL10n.text("Вставьте ключ выбранного API")))
            .font(JotUI.TypeScale.code)
        HStack {
            Button(JotL10n.text("Сохранить ключ")) {
                guard endpoint.url != nil else { message = JotL10n.text("Сначала укажите корректный URL API."); return }
                let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                if KeychainStore.saveAPIKey(key, account: endpoint.credentialAccount) {
                    draft = ""; hasKey = true
                    message = JotL10n.text("Ключ сохранён. Доступ к модели проверится при запросе.")
                } else { message = JotL10n.text("Не удалось сохранить ключ в Keychain.") }
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if hasKey {
                Button(JotL10n.text("Удалить ключ"), role: .destructive) {
                    KeychainStore.deleteAPIKey(notify: true, account: endpoint.credentialAccount)
                    hasKey = false; message = JotL10n.text("Ключ удалён."); draft = ""
                }
            }
        }
        if !message.isEmpty { Text(message).font(JotUI.TypeScale.labelSmall()).foregroundStyle(.secondary) }
        Text(JotL10n.text("Ключ привязан к этому URL и хранится только в macOS Keychain. Смена адреса требует ключа для нового API."))
            .font(JotUI.TypeScale.labelSmall()).foregroundStyle(.secondary)
            .onAppear { refresh() }
            .onChange(of: endpoint.credentialAccount) { _, _ in draft = ""; message = ""; refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange)) { note in
                if note.object as? String == "apiKey" { refresh() }
            }
    }
    private func refresh() { hasKey = KeychainStore.loadAPIKey(account: endpoint.credentialAccount) != nil }
}
