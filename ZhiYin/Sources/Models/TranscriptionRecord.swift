import Foundation
import SwiftData

@Model
final class TranscriptionRecord {
    var id: UUID
    var text: String
    var timestamp: Date
    var duration: TimeInterval
    var audioFilePath: String?
    /// Source of the record: "stt" for normal transcription, "ai_agent" for AI Agent replies
    var source: String?
    /// For AI Agent records: the user's voice intent that triggered the reply
    var aiIntent: String?
    /// For AI Agent records: which agent was used (e.g. "Email", "Chat")
    var aiAgentName: String?

    init(text: String, duration: TimeInterval, audioFilePath: String? = nil, source: String = "stt", aiIntent: String? = nil, aiAgentName: String? = nil) {
        self.id = UUID()
        self.text = text
        self.timestamp = Date()
        self.duration = duration
        self.audioFilePath = audioFilePath
        self.source = source
        self.aiIntent = aiIntent
        self.aiAgentName = aiAgentName
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
