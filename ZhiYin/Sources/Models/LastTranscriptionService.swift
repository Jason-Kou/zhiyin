import Foundation
import SwiftData
import AppKit

/// Helpers for the two "last transcription" menu actions inspired by VoiceInk:
/// Copy Last Transcription and Retry Last Transcription.
@MainActor
enum LastTranscriptionService {
    /// Fetch the most recent TranscriptionRecord from history, or nil if none exist.
    static func latest() -> TranscriptionRecord? {
        var descriptor = FetchDescriptor<TranscriptionRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? HistoryStore.shared.container.mainContext.fetch(descriptor))?.first
    }

    /// Whether a last transcription exists (for menu item enablement).
    static var hasAny: Bool { latest() != nil }

    /// Whether the last transcription still has a playable audio file (for retry enablement).
    static var canRetry: Bool { latest()?.hasAudioFile ?? false }

    /// Copy the last transcription's text to the system clipboard.
    /// - Returns: true on success, false if there is no last record.
    @discardableResult
    static func copyLast() -> Bool {
        guard let record = latest(), !record.text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(record.text, forType: .string)
        return true
    }

    /// Re-transcribe the last record's audio file in place, then copy the fresh
    /// text to the clipboard. Updates the existing record's `text` rather than
    /// creating a new history entry.
    /// - Returns: the new text on success, nil on failure.
    static func retryLast(using transcriber: SenseVoiceTranscriber) async -> String? {
        guard let record = latest(),
              let audioURL = record.audioURL,
              FileManager.default.fileExists(atPath: audioURL.path) else {
            return nil
        }

        do {
            let newText = try await transcriber.transcribe(audioURL: audioURL)
            let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            record.text = trimmed
            try? HistoryStore.shared.container.mainContext.save()

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(trimmed, forType: .string)
            return trimmed
        } catch {
            print("LastTranscriptionService: retry failed - \(error.localizedDescription)")
            return nil
        }
    }
}
