// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation

public enum AudioUploadEncoder {
    /// Keep the crash-safe CAF; prepare derived upload data off the main actor.
    public static func wav(from source: URL) throws -> Data {
        let reader = try AVAudioFile(forReading: source, commonFormat: .pcmFormatInt16, interleaved: true)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("jot-upload-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: target) }
        do {
            let writer = try AVAudioFile(forWriting: target, settings: reader.processingFormat.settings,
                                         commonFormat: .pcmFormatInt16, interleaved: true)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 65_536) else {
                throw TranscriptionError.badRequest(JotL10n.text("Не удалось подготовить аудио."))
            }
            while reader.framePosition < reader.length {
                try Task.checkCancellation()
                try reader.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try writer.write(from: buffer)
            }
        }
        return try Data(contentsOf: target)
    }
}
