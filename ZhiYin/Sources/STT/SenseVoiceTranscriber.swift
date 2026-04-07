import Foundation

/// STT transcriber — streams audio chunks to server, VAD detects sentence boundaries,
/// server auto-transcribes completed sentences.
class SenseVoiceTranscriber {
    private var serverURL: String { ServerConfig.baseURL }
    private let session: URLSession

    /// Active streaming session ID
    private(set) var activeSessionId: String?

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config)
    }

    // MARK: - Legacy (full file upload)

    func transcribe(audioURL: URL) async throws -> String {
        let url = URL(string: "\(serverURL)/transcribe")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioURL)
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw TranscriberError.serverError
        }

        let json = try JSONDecoder().decode(TranscribeResponse.self, from: data)
        return json.text
    }

    // MARK: - Streaming Session

    func startSession() async throws -> String {
        let url = URL(string: "\(serverURL)/stream/start")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw TranscriberError.serverError
        }

        let json = try JSONDecoder().decode(SessionStartResponse.self, from: data)
        activeSessionId = json.session_id
        return json.session_id
    }

    /// Send audio chunk. Returns transcribed text so far (VAD auto-transcribes completed sentences).
    func sendChunk(samples: [Float]) async throws -> ChunkResult {
        guard let sessionId = activeSessionId else {
            throw TranscriberError.noActiveSession
        }

        let url = URL(string: "\(serverURL)/stream/chunk/\(sessionId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let data = samples.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        request.httpBody = data

        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw TranscriberError.serverError
        }

        return try JSONDecoder().decode(ChunkResult.self, from: responseData)
    }

    /// Poll current streaming text without finalizing (for instant results when Final Touch is off).
    func pollText(sessionId: String) async throws -> String {
        let url = URL(string: "\(serverURL)/stream/poll/\(sessionId)")!
        let (data, response) = try await session.data(for: URLRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw TranscriberError.serverError
        }
        let json = try JSONDecoder().decode(PollResponse.self, from: data)
        return json.text
    }

    /// Finalize: transcribe remaining audio, return complete text, close session.
    /// - Parameter mode: "full" for complete re-transcription, "quick" for tail-only
    func finalizeSession(mode: String = "full") async throws -> String {
        guard let sessionId = activeSessionId else {
            throw TranscriberError.noActiveSession
        }

        let url = URL(string: "\(serverURL)/stream/finalize/\(sessionId)?mode=\(mode)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60

        let (data, response) = try await session.data(for: request)
        activeSessionId = nil

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw TranscriberError.serverError
        }

        let json = try JSONDecoder().decode(FinalizeResponse.self, from: data)
        return json.text
    }

    func cancelSession() async {
        guard let sessionId = activeSessionId else { return }
        activeSessionId = nil
        guard let url = URL(string: "\(serverURL)/stream/\(sessionId)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try? await session.data(for: request)
    }

    // MARK: - Health

    func isServerReady() async -> Bool {
        guard let url = URL(string: "\(serverURL)/health") else { return false }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Server is ready when VAD is loaded AND active engine model is loaded
                let vadLoaded = json["vad_loaded"] as? Bool ?? false
                let asrLoaded = json["asr_loaded"] as? Bool ?? false
                if !vadLoaded { return false }
                return asrLoaded  // asr_loaded now reflects the ACTIVE engine's model state
            }
            return false
        } catch {
            return false
        }
    }

    // MARK: - Types

    enum TranscriberError: Error {
        case serverError
        case noActiveSession
    }

    private struct TranscribeResponse: Decodable {
        let text: String
        let time: Double?
    }

    private struct SessionStartResponse: Decodable {
        let session_id: String
    }

    struct ChunkResult: Decodable {
        let ok: Bool
        let text: String?
        let version: Int?
        let segments: Int?
        let duration: Double?
    }

    private struct FinalizeResponse: Decodable {
        let text: String
        let segments: Int?
        let duration: Double?
    }

    private struct PollResponse: Decodable {
        let text: String
        let version: Int?
        let segments: Int?
    }
}
