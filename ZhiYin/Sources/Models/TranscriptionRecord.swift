import Foundation
import SwiftData

@Model
final class TranscriptionRecord {
    var id: UUID
    var text: String
    var timestamp: Date
    var duration: TimeInterval
    var audioFilePath: String?

    init(text: String, duration: TimeInterval, audioFilePath: String? = nil) {
        self.id = UUID()
        self.text = text
        self.timestamp = Date()
        self.duration = duration
        self.audioFilePath = audioFilePath
    }

    /// Whether the audio file still exists on disk
    var hasAudioFile: Bool {
        guard let path = audioFilePath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    var audioURL: URL? {
        guard let path = audioFilePath else { return nil }
        return URL(fileURLWithPath: path)
    }
}
