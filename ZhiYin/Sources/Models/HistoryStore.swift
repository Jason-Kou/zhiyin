import Foundation
import SwiftData

/// Manages the SwiftData container and provides convenience methods
/// for saving transcription records and cleaning up old audio files.
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    let container: ModelContainer

    /// Directory for persisted audio recordings
    static let recordingsDir: String = {
        let path = NSString(string: "~/.zhiyin/recordings").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()

    private init() {
        let schema = Schema([TranscriptionRecord.self])
        let config = ModelConfiguration("ZhiYinHistory", schema: schema)
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
    }

    /// Save a new transcription record, optionally preserving the audio file.
    /// - Parameters:
    ///   - text: Transcribed text
    ///   - duration: Recording duration in seconds
    ///   - tempAudioURL: Temporary WAV file from AudioRecorder (will be moved to persistent storage)
    func save(text: String, duration: TimeInterval, tempAudioURL: URL?) {
        var savedPath: String?
        if let src = tempAudioURL, FileManager.default.fileExists(atPath: src.path) {
            let dest = "\(Self.recordingsDir)/\(UUID().uuidString).wav"
            do {
                try FileManager.default.copyItem(atPath: src.path, toPath: dest)
                savedPath = dest
            } catch {
                print("Failed to save audio for history: \(error)")
            }
        }

        let record = TranscriptionRecord(text: text, duration: duration, audioFilePath: savedPath, source: "stt")
        container.mainContext.insert(record)
        try? container.mainContext.save()
    }

    /// Save the user's voice intent from AI Agent mode to history for debugging.
    func saveAIReply(intent: String, agentName: String, duration: TimeInterval, tempAudioURL: URL?) {
        var savedPath: String?
        if let src = tempAudioURL, FileManager.default.fileExists(atPath: src.path) {
            let dest = "\(Self.recordingsDir)/\(UUID().uuidString).wav"
            do {
                try FileManager.default.copyItem(atPath: src.path, toPath: dest)
                savedPath = dest
            } catch {
                print("Failed to save audio for AI history: \(error)")
            }
        }

        let record = TranscriptionRecord(
            text: intent, duration: duration, audioFilePath: savedPath,
            source: "ai_agent", aiAgentName: agentName
        )
        container.mainContext.insert(record)
        try? container.mainContext.save()
    }

    /// Delete a record and its audio file from disk.
    func delete(_ record: TranscriptionRecord) {
        if let path = record.audioFilePath {
            try? FileManager.default.removeItem(atPath: path)
        }
        container.mainContext.delete(record)
        try? container.mainContext.save()
    }

    /// Remove recordings older than the given number of days.
    func cleanupOldRecords(olderThanDays days: Int = 30) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let predicate = #Predicate<TranscriptionRecord> { $0.timestamp < cutoff }
        let descriptor = FetchDescriptor(predicate: predicate)
        do {
            let old = try container.mainContext.fetch(descriptor)
            for record in old {
                delete(record)
            }
        } catch {
            print("Cleanup failed: \(error)")
        }
    }
}
