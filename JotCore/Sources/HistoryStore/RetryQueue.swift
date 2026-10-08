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
import Network

/// The offline queue (F1, critic reconciliation #5): drains on network-restored
/// and on launch; one session at a time; drained results NOTIFY and land in
/// History — never auto-insert (focus is long gone). Simple policy: no exponential
/// ladders; the network path monitor IS the retry signal.
@MainActor
public final class RetryQueue {
    private let store: HistoryStore
    private let transcription: TranscriptionServicing
    private let settings: SettingsStore
    private let monitor = NWPathMonitor()
    private var draining = false
    private var lastPathSatisfied = false

    public var onDrained: ((Int) -> Void)?
    /// Fired once per blocked API profile (auth/quota/balance) — rows KEEP their queued promise and retry on the
    /// next external signal (launch, network flap, key change).
    public var onDrainBlocked: ((TranscriptionError) -> Void)?

    public init(store: HistoryStore, transcription: TranscriptionServicing, settings: SettingsStore = SettingsStore()) {
        self.store = store
        self.transcription = transcription
        self.settings = settings
    }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let satisfied = path.status == .satisfied
                let cameOnline = satisfied && !self.lastPathSatisfied
                self.lastPathSatisfied = satisfied
                if cameOnline {
                    Log.history.info("RetryQueue: network restored — draining")
                    await self.drain()
                }
            }
        }
        monitor.start(queue: .main)
        Task { await drain() } // launch drain
    }

    public func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }

        let retryable = store.retryableRecords()
        guard !retryable.isEmpty else { return }
        var recoveredCount = 0
        var blockedAccounts = Set<String>()
        for record in retryable {
            let configuration = SessionMeta.read(from: record.folderURL)?.configuration ?? settings.legacyTranscriptionConfiguration
            let account = configuration.recognition.credentialAccount
            guard !blockedAccounts.contains(account) else { continue }

            switch await process(record) {
            case .recovered:
                recoveredCount += 1
            case .stillOffline:
                Log.history.info("RetryQueue: still offline — pausing drain")
                if recoveredCount > 0 { onDrained?(recoveredCount) }
                return
            case .blocked(let error):
                // Skip this credential profile, while other providers can proceed.
                Log.history.warning("RetryQueue: drain blocked (\(String(describing: error))) — keeping queue intact")
                blockedAccounts.insert(account)
                onDrainBlocked?(error)
                continue
            case .failed, .skipped:
                continue
            }
        }
        if recoveredCount > 0 {
            onDrained?(recoveredCount)
        }
    }

    /// Manual per-item retry (History context menu) — works on any record.
    /// Shares the draining guard so a manual retry can't double-process a record
    /// the drain is already sending (audit L20).
    public func retrySingle(_ record: DictationRecord, useCurrentConfiguration: Bool = false) async -> RetryOutcome {
        guard !draining else { return .busy }
        draining = true
        defer { draining = false }
        var target = record
        if useCurrentConfiguration {
            // Explicit reprocessing creates a new history item; keep the old text intact.
            do {
                guard let old = SessionMeta.read(from: record.folderURL) else { return .failed }
                let id = UUID()
                let folder = try FileLayout.makeSessionFolder(id: id)
                do {
                    try FileManager.default.copyItem(at: FileLayout.audioCAF(in: record.folderURL), to: FileLayout.audioCAF(in: folder))
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    return .failed
                }
                var meta = SessionMeta(id: id, startedAt: Date(), status: .queuedForRetry)
                meta.configuration = settings.transcriptionConfiguration
                meta.audioDurationSeconds = old.audioDurationSeconds
                meta.targetAppBundleID = old.targetAppBundleID
                meta.targetAppName = old.targetAppName
                meta.write(to: folder)
                store.upsert(meta: meta, folder: folder)
                target = DictationRecord(meta: meta, folder: folder)
            } catch { return .failed }
        }
        switch await process(target) {
        case .recovered:
            onDrained?(1)
            return .recovered
        case .stillOffline:
            return .stillOffline
        case .blocked(let error):
            onDrainBlocked?(error)
            return .blocked
        case .failed:
            return .failed
        case .skipped:
            return .alreadyDone
        }
    }

    /// User-facing outcome of a manual Retry — a silent no-op reads as broken.
    public enum RetryOutcome { case recovered, stillOffline, blocked, failed, alreadyDone, busy }

    private enum ProcessResult { case recovered, stillOffline, blocked(TranscriptionError), failed, skipped }

    private func process(_ record: DictationRecord) async -> ProcessResult {
        let folder = record.folderURL
        guard var meta = SessionMeta.read(from: folder) else { return .skipped }
        // Re-read status from disk: a concurrent path may have finished it already.
        if meta.status == .awaitingChip || meta.status == .inserted || meta.status == .recovered {
            return .skipped
        }
        // Transcript already exists (crash after transcription, audio since
        // purged): recover the WORDS instead of dead-ending on missing audio.
        if meta.rawTranscript != nil {
            meta.status = .recovered
            meta.errorCode = nil
            meta.write(to: folder)
            store.upsert(meta: meta, folder: folder)
            return .recovered
        }
        let cafURL = FileLayout.audioCAF(in: folder)
        guard FileManager.default.fileExists(atPath: cafURL.path) else {
            meta.status = .failed
            meta.errorCode = "audio_purged"
            meta.write(to: folder)
            store.upsert(meta: meta, folder: folder)
            return .failed
        }
        do {
            if meta.configuration == nil {
                meta.configuration = settings.legacyTranscriptionConfiguration
                meta.write(to: folder)
            }
            let context = DictationContext(
                targetAppBundleID: meta.targetAppBundleID,
                targetAppName: meta.targetAppName,
                configuration: meta.configuration ?? settings.legacyTranscriptionConfiguration
            )
            let store = self.store
            let result = try await transcription.transcribe(
                audioURL: cafURL,
                durationSeconds: meta.audioDurationSeconds
                    ?? FileLayout.estimatedDuration(ofCAF: cafURL)
                    ?? 60,
                context: context,
                onRawTranscript: { raw in
                    await MainActor.run { store.preserveRawTranscript(raw, folder: folder) }
                }
            )
            meta.rawTranscript = result.rawTranscript
            meta.cleanedTranscript = result.cleanedTranscript
            meta.modelID = result.modelID
            // .recovered, NOT .awaitingChip: the text was never put on the
            // clipboard, so no chip may promise "Ready to paste".
            meta.status = .recovered
            meta.write(to: folder)
            store.upsert(meta: meta, folder: folder)
            return .recovered
        } catch is CancellationError {
            return .skipped
        } catch let error as TranscriptionError {
            switch error {
            case .offline, .network, .timeout, .rateLimitedTransient:
                return .stillOffline
            case .auth, .rateLimitedDaily, .insufficientBalance:
                // Account-level wall: NOT this row's fault. Keep its queued
                // status untouched so the promise survives to the next drain.
                return .blocked(error)
            case .modelUnavailable(let model, let detail):
                meta.status = .failed
                meta.errorCode = "model"
                meta.errorMessage = detail ?? "model \(model) not accessible"
                meta.write(to: folder)
                store.upsert(meta: meta, folder: folder)
                return .failed
            case .badRequest(let message):
                // Permanent (audit #3): mark failed so the queue never spins on it.
                meta.status = .failed
                meta.errorCode = "bad_request"
                meta.errorMessage = message
                meta.write(to: folder)
                store.upsert(meta: meta, folder: folder)
                Log.history.warning("RetryQueue: permanent failure for \(meta.id, privacy: .public): \(message, privacy: .private)")
                return .failed
            default:
                meta.status = .failed
                meta.errorCode = "retry_\(String(describing: error))"
                meta.write(to: folder)
                store.upsert(meta: meta, folder: folder)
                return .failed
            }
        } catch {
            // Non-TranscriptionError (e.g. FLAC encode on a corrupt CAF): mark it
            // failed so the queue never spins on it (audit L3).
            Log.history.error("RetryQueue: unexpected error \(error)")
            meta.status = .failed
            meta.errorCode = "retry_unexpected"
            meta.write(to: folder)
            store.upsert(meta: meta, folder: folder)
            return .failed
        }
    }
}
