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
import AVFoundation
import SwiftUI
import JotCore

/// The History pane of the main window: proof that nothing is ever lost.
/// Stats up top, day-grouped searchable list, row → detail sheet with
/// Cleaned/Raw, audio playback, retry, delete.
struct HistoryPane: View {
    let store: HistoryStore
    let onRetry: (DictationRecord, Bool) -> Void

    @State private var query = ""
    @State private var records: [DictationRecord] = []
    @State private var stats = HistoryStore.Stats(totalWords: 0, totalDictations: 0, averageWPM: 0)
    @State private var detailRecord: DictationRecord?
    @State private var showAllAttention = false
    @State private var confirmingDiscardAll = false
    @Environment(\.colorScheme) private var scheme
    private var grad: CGFloat { scheme == .dark ? 25 : 0 }

    var body: some View {
        VStack(spacing: 0) {
            header
            if records.isEmpty {
                emptyState
            } else {
                recordList
            }
        }
        .onAppear(perform: reload)
        // Live pane: dictations landing, retries draining, and deletions all
        // announce themselves — no polling, no guessed delays.
        .onReceive(
            NotificationCenter.default.publisher(for: .gtHistoryDidChange)
                .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
        ) { _ in
            reload()
        }
        .sheet(item: $detailRecord) { record in
            RecordDetailSheet(
                record: record,
                onRetry: { onRetry(record, false) },
                onReprocess: { onRetry(record, true) },
                onDelete: {
                    store.delete(id: record.id, removeFolder: true)
                    detailRecord = nil
                    reload()
                }
            )
        }
    }

    // MARK: - Header (stats + search)

    private var header: some View {
        VStack(spacing: JotUI.Spacing.s) {
            HStack(spacing: JotUI.Spacing.xl) {
                stat(value: "\(stats.totalWords)", label: JotL10n.text("words dictated"))
                stat(value: "\(stats.totalDictations)", label: "dictations")
                stat(value: stats.averageWPM > 0 ? "\(stats.averageWPM)" : "—", label: JotL10n.text("avg WPM"))
                Spacer()
                HStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule().fill(JotUI.Colors.brandQuad[index])
                            .frame(width: 12, height: 4)
                    }
                }
            }
            HStack(spacing: JotUI.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(JotL10n.text("Search your dictations"), text: $query)
                    .textFieldStyle(.plain)
                    .font(JotUI.TypeScale.body(grad: grad))
                    .onChange(of: query) { _, _ in reload() }
            }
            .padding(.horizontal, JotUI.Spacing.s)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: JotUI.Radius.small).fill(.quaternary.opacity(0.5)))
        }
        .padding(.horizontal, JotUI.Spacing.l)
        .padding(.top, JotUI.Spacing.l)
        .padding(.bottom, JotUI.Spacing.s)
    }

    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(JotUI.TypeScale.title(grad: grad))
                .monospacedDigit()
            Text(label)
                .font(JotUI.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - List

    private var groupedTimeline: [(day: String, items: [DictationRecord])] {
        let formatter = DateFormatter()
        formatter.locale = JotL10n.locale
        formatter.dateStyle = .medium
        formatter.doesRelativeDateFormatting = true
        var groups: [(String, [DictationRecord])] = []
        for record in timeline {
            let day = formatter.string(from: record.startedAt)
            if groups.last?.0 == day {
                groups[groups.count - 1].1.append(record)
            } else {
                groups.append((day, [record]))
            }
        }
        return groups.map { (day: $0.0, items: $0.1) }
    }

    /// Rows needing action (retryable) — pinned above the timeline of words.
    private var attention: [DictationRecord] {
        records.filter { record in
            record.displayText.isEmpty || SessionMeta.Status(rawValue: record.status) == .queuedForRetry
                || SessionMeta.Status(rawValue: record.status) == .failed
        }
    }

    private var timeline: [DictationRecord] {
        records.filter { record in
            !record.displayText.isEmpty && SessionMeta.Status(rawValue: record.status) != .queuedForRetry
                && SessionMeta.Status(rawValue: record.status) != .failed
        }
    }

    private var recordList: some View {
        List {
            if !attention.isEmpty {
                Section {
                    // Capped shelf: attention must never bury the timeline of words.
                    ForEach(showAllAttention ? attention : Array(attention.prefix(3)), id: \.id) { record in
                        attentionRow(record)
                    }
                    if attention.count > 3 {
                        Button(showAllAttention ? JotL10n.text("Show less") : JotL10n.format("Show %@ more", String(describing: attention.count - 3))) {
                            showAllAttention.toggle()
                        }
                        .buttonStyle(.link)
                        .font(JotUI.TypeScale.labelSmall(grad: grad))
                    }
                } header: {
                    HStack(spacing: JotUI.Spacing.xxs) {
                        Circle().fill(JotUI.Colors.gYellow).frame(width: 6, height: 6)
                        Text(JotL10n.format("Needs attention (%@)", String(describing: attention.count)))
                            .font(JotUI.TypeScale.labelSmall(grad: grad))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(JotL10n.text("Discard All")) {
                            confirmingDiscardAll = true
                        }
                        .buttonStyle(.link)
                        .font(JotUI.TypeScale.labelSmall(grad: grad))
                        .confirmationDialog(
                            JotL10n.format("Discard all %@ recordings that need attention? Their audio will be deleted.", String(describing: attention.count)),
                            isPresented: $confirmingDiscardAll
                        ) {
                            Button(JotL10n.format("Discard %@ Recordings", String(describing: attention.count)), role: .destructive) {
                                for record in attention {
                                    store.delete(id: record.id, removeFolder: true)
                                }
                                reload()
                            }
                        }
                    }
                }
            }
            ForEach(groupedTimeline, id: \.day) { group in
                Section {
                    ForEach(group.items, id: \.id) { record in
                        row(record)
                    }
                } header: {
                    Text(group.day)
                        .font(JotUI.TypeScale.labelSmall(grad: grad))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func attentionRow(_ record: DictationRecord) -> some View {
        HStack(spacing: JotUI.Spacing.s) {
            VStack(alignment: .leading, spacing: 3) {
                Text(attentionTitle(record))
                    .font(JotUI.TypeScale.body(grad: grad))
                    .foregroundStyle(.primary)
                HStack(spacing: JotUI.Spacing.xs) {
                    if let app = record.targetAppName { Text(app) }
                    if let duration = record.durationSeconds {
                        Text(String(format: JotL10n.text("%.0fs of audio"), duration))
                    }
                    Text(record.startedAt.formatted(.dateTime.day().month().year().hour().minute().locale(JotL10n.locale)))
                }
                .font(JotUI.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(.secondary)
            }
            Spacer()
            // Retry needs something to retry: no audio and no transcript is a
            // dead-end button that can only re-fail (production pass 2).
            if audioExists(record) || record.rawTranscript != nil {
                Button(JotL10n.text("Retry")) {
                    onRetry(record, false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Button {
                store.delete(id: record.id, removeFolder: true)
                reload()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(JotL10n.text("Discard this recording"))
        }
        .padding(.vertical, 3)
    }

    private func audioExists(_ record: DictationRecord) -> Bool {
        FileManager.default.fileExists(atPath: FileLayout.audioCAF(in: record.folderURL).path)
    }

    private func attentionTitle(_ record: DictationRecord) -> String {
        switch SessionMeta.Status(rawValue: record.status) {
        case .queuedForRetry: return JotL10n.text("Waiting for network")
        case .cancelled:
            // Only claim "audio kept" when it actually is (retention truth).
            return audioExists(record)
                ? JotL10n.text("Cancelled recording — audio kept")
                : JotL10n.text("Cancelled recording — audio deleted by your retention setting")
        case .failed where record.errorCode == "audio_purged":
            return JotL10n.text("Audio was deleted by your retention setting")
        case .failed where record.errorCode == "tooNoisy":
            return JotL10n.text("Too noisy — no speech heard")
        case .failed where record.errorCode == "bad_request": return JotL10n.text("Couldn't process this one")
        case .failed where record.errorCode == "model": return JotL10n.text("Model not available to your key — see Settings → Advanced")
        case .failed: return JotL10n.text("Transcription failed")
        default: return JotL10n.text("Recovered recording")
        }
    }

    private func row(_ record: DictationRecord) -> some View {
        Button {
            detailRecord = record
        } label: {
            HStack(spacing: JotUI.Spacing.s) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.displayText.isEmpty ? "—" : String(record.displayText.prefix(110)))
                        .font(JotUI.TypeScale.body(grad: grad))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: JotUI.Spacing.xs) {
                        if let app = record.targetAppName {
                            Text(app)
                        }
                        if let duration = record.durationSeconds {
                            Text(String(format: JotL10n.text("%.0f с"), duration))
                        }
                        Text(record.startedAt.formatted(.dateTime.hour().minute().locale(JotL10n.locale)))
                    }
                    .font(JotUI.TypeScale.labelSmall(grad: grad))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                statusChip(record)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(JotL10n.text("Copy")) { copy(record) }
            Button(JotL10n.text("Retry Transcription")) { onRetry(record, false) }
            Divider()
            Button(JotL10n.text("Delete"), role: .destructive) {
                store.delete(id: record.id, removeFolder: true)
                reload()
            }
        }
    }

    @ViewBuilder
    private func statusChip(_ record: DictationRecord) -> some View {
        // Timeline rows all carry words; only paste-state chips remain relevant
        // (failures live in the Needs-attention shelf above).
        switch SessionMeta.Status(rawValue: record.status) {
        case .awaitingChip:
            // Only trustworthy for a few minutes — the clipboard moves on.
            if Date().timeIntervalSince(record.startedAt) < 300 {
                chip(JotL10n.text("Ready to paste"), color: JotUI.Colors.primary)
            } else {
                chip(JotL10n.text("Wasn't pasted"), color: Color.secondary)
            }
        case .recovered:
            chip(JotL10n.text("Recovered"), color: JotUI.Colors.primary)
        case .heldSecure:
            chip(JotL10n.text("Kept — secure field"), color: Color.secondary)
        case .cancelled:
            chip(JotL10n.text("Cancelled"), color: Color.secondary)
        default:
            EmptyView()
        }
    }

    /// Human words, never raw enum values, in the detail sheet.
    static func statusDisplayName(_ record: DictationRecord) -> String {
        switch SessionMeta.Status(rawValue: record.status) {
        case .inserted: return JotL10n.text("Inserted at the cursor")
        case .copiedToClipboard: return JotL10n.text("Copied to the clipboard")
        case .awaitingChip: return JotL10n.text("Ready to paste")
        case .recovered: return JotL10n.text("Recovered — use Copy to grab the text")
        case .heldSecure: return JotL10n.text("Kept — secure field blocked insertion")
        case .queuedForRetry: return JotL10n.text("Queued — retries automatically")
        case .cancelled: return JotL10n.text("Cancelled")
        case .failed: return JotL10n.text("Failed")
        case .silent: return JotL10n.text("No speech detected")
        case .recording, .recorded, .transcribing, .none: return record.status
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(JotUI.TypeScale.labelSmall(grad: grad))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private var emptyState: some View {
        VStack(spacing: JotUI.Spacing.m) {
            Spacer()
            HStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(JotUI.Colors.brandQuad[index])
                        .frame(width: 6, height: [18, 30, 24, 14][index])
                }
            }
            Text(JotL10n.text("Nothing here yet"))
                .font(JotUI.TypeScale.title(grad: grad))
            Text(JotL10n.text("Hold fn and say hello."))
                .font(JotUI.TypeScale.body(grad: grad))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func copy(_ record: DictationRecord) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(record.displayText, forType: .string)
    }

    private func reload() {
        records = store.records(matching: query.isEmpty ? nil : query)
        stats = store.stats()
    }

}

// MARK: - Detail sheet

private struct RecordDetailSheet: View {
    let record: DictationRecord
    let onRetry: () -> Void
    let onReprocess: () -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var showRaw = false
    @State private var player: AVAudioPlayer?
    private var grad: CGFloat { scheme == .dark ? 25 : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: JotUI.Spacing.m) {
            HStack {
                // Native smart transcription formats as it transcribes, so on the
                // default path there is no separate raw text to compare against —
                // the two tabs would be byte-identical. A segmented control whose
                // halves match reads as broken, so it only appears when a second
                // model actually rewrote something.
                if hasDistinctRaw {
                    Picker("", selection: $showRaw) {
                        Text(JotL10n.text("Cleaned")).tag(false)
                        Text(JotL10n.text("Raw")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }
                Spacer()
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(shownText, forType: .string)
                } label: {
                    Label(JotL10n.text("Copy"), systemImage: "doc.on.doc")
                }
            }

            ScrollView {
                Text(shownText)
                    .font(JotUI.TypeScale.bodyLarge(grad: grad))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 260)

            HStack(spacing: JotUI.Spacing.s) {
                audioButton
                Button(JotL10n.text("Retry Transcription")) { onRetry() }
                    .help(JotL10n.text("Использует сохранённые URL, модель и язык этой записи."))
                Button(JotL10n.text("С текущей моделью")) { onReprocess() }
                    .disabled(!FileManager.default.fileExists(atPath: FileLayout.audioCAF(in: record.folderURL).path))
                    .help(JotL10n.text("Повторно отправит аудио в выбранный сейчас API. Создаст новую запись в истории; запрос может быть платным."))
                Spacer()
                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                }
                .help(JotL10n.text("Delete this dictation"))
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: JotUI.Spacing.l, verticalSpacing: 4) {
                if let app = record.targetAppName {
                    GridRow {
                        metaLabel(JotL10n.text("Dictated into")); metaValue(app)
                    }
                }
                if let provider = record.provider {
                    GridRow { metaLabel(JotL10n.text("Провайдер")); metaValue(JotL10n.text(provider)) }
                }
                if let url = record.apiBaseURL {
                    GridRow { metaLabel("API"); metaValue(url) }
                }
                if let model = record.modelID {
                    GridRow { metaLabel(JotL10n.text("Модель")); metaValue(model) }
                }
                GridRow { metaLabel(JotL10n.text("Язык")); metaValue(record.language ?? JotL10n.text("Авто")) }
                if let duration = record.durationSeconds {
                    GridRow {
                        metaLabel(JotL10n.text("Duration")); metaValue(String(format: JotL10n.text("%.1f с"), duration))
                    }
                }
                if let pipeline = record.pipelineSeconds {
                    GridRow {
                        metaLabel(JotL10n.text("Pipeline")); metaValue(String(format: JotL10n.text("%.2f с"), pipeline))
                    }
                }
                GridRow {
                    metaLabel(JotL10n.text("Status")); metaValue(HistoryPane.statusDisplayName(record))
                }
                if let message = record.errorMessage, !message.isEmpty {
                    GridRow {
                        metaLabel(JotL10n.text("Details")); metaValue(String(message.prefix(160)))
                    }
                }
            }

            HStack {
                Spacer()
                Button(JotL10n.text("Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(JotUI.Spacing.l)
        .frame(width: 520)
        .onDisappear { player?.stop() }
    }

    private var hasDistinctRaw: Bool {
        guard let raw = record.rawTranscript, let clean = record.cleanedTranscript else { return false }
        return raw != clean
    }

    private var shownText: String {
        (showRaw && hasDistinctRaw) ? (record.rawTranscript ?? "—")
                : (record.cleanedTranscript ?? record.rawTranscript ?? "—")
    }

    @ViewBuilder
    private var audioButton: some View {
        let cafURL = FileLayout.audioCAF(in: record.folderURL)
        if FileManager.default.fileExists(atPath: cafURL.path) {
            Button {
                if player?.isPlaying == true {
                    player?.stop()
                    player = nil
                } else {
                    player = try? AVAudioPlayer(contentsOf: cafURL)
                    player?.play()
                }
            } label: {
                Label(player?.isPlaying == true ? JotL10n.text("Stop") : JotL10n.text("Play Audio"),
                      systemImage: player?.isPlaying == true ? "stop.fill" : "play.fill")
            }
        } else {
            Text(JotL10n.text("Audio removed by retention policy"))
                .font(JotUI.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(.secondary)
        }
    }

    private func metaLabel(_ text: String) -> some View {
        Text(text).font(JotUI.TypeScale.labelSmall(grad: grad)).foregroundStyle(.secondary)
    }

    private func metaValue(_ text: String) -> some View {
        Text(text).font(JotUI.TypeScale.labelSmall(grad: grad))
    }
}
