import Foundation
import CoreGraphics

/// Errors that can occur during AI reply generation.
enum AIReplyError: Error, LocalizedError {
    case serverNotRunning
    case requestFailed(String)
    case parseFailed
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .serverNotRunning:
            return "LLM server is not running or unreachable. Please check your AI provider settings."
        case .requestFailed(let details):
            return "LLM request failed: \(details)"
        case .parseFailed:
            return "Could not parse LLM response"
        case .emptyResponse:
            return "LLM returned an empty response"
        }
    }
}

/// Manages contextual AI reply generation.
/// Routes requests through AIProviderManager (Ollama, OpenRouter, Gemini, Local CLI, Custom).
class ContextualReplyManager {
    static let shared = ContextualReplyManager()

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "aiReplyEnabled") }
    }

    private var provider: AIProviderManager { AIProviderManager.shared }

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: "aiReplyEnabled")
    }

    // MARK: - Generate Reply

    /// Generates a contextual reply by sending a screenshot + user intent to the configured LLM.
    func generateReply(screenshot: CGImage?, intent: String, agent: AIAgent? = nil) async throws -> String {
        let systemPrompt = buildSystemPrompt(for: agent)

        // Local CLI path
        if provider.selectedProvider == .localCLI {
            let userMsg = "User's intent: \(intent)"
            guard let result = await provider.executeCLI(systemPrompt: systemPrompt, userPrompt: userMsg) else {
                throw AIReplyError.emptyResponse
            }
            return result
        }

        // Native Gemini path — the OpenAI-compat endpoint rejects new AQ.* keys (HTTP 400
        // "Multiple authentication credentials received"), so we call `:generateContent`
        // directly with the x-goog-api-key header.
        if provider.selectedProvider == .gemini {
            let model = provider.currentModel
            let hasVision = AIProviderType.modelSupportsVision(model, provider: .gemini)
            let base64 = screenshot.map { ScreenshotCapture.shared.encodeScreenshotToBase64($0) } ?? ""
            let body = buildGeminiRequestBody(systemPrompt: systemPrompt, base64: base64, intent: intent, hasVision: hasVision)

            guard let url = buildGeminiURL(model: model, stream: false) else {
                throw AIReplyError.requestFailed("Invalid Gemini URL for model \(model)")
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 60
            let key = provider.currentAPIKey
            guard !key.isEmpty else {
                throw AIReplyError.requestFailed("Missing Gemini API key")
            }
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            } catch {
                throw AIReplyError.requestFailed("Failed to build Gemini request body")
            }

            print("ContextualReplyManager: Gemini (native) → \(model) @ \(url.absoluteString)")

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch let urlError as URLError {
                print("ContextualReplyManager: Gemini connection error - \(urlError.localizedDescription)")
                throw AIReplyError.serverNotRunning
            } catch {
                print("ContextualReplyManager: Gemini request error - \(error.localizedDescription)")
                throw AIReplyError.serverNotRunning
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AIReplyError.requestFailed("Invalid response type")
            }
            guard httpResponse.statusCode == 200 else {
                let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
                print("ContextualReplyManager: Gemini HTTP \(httpResponse.statusCode) - \(bodyStr)")
                throw AIReplyError.requestFailed("HTTP \(httpResponse.statusCode)")
            }
            return try parseGeminiResponse(data)
        }

        // OpenAI-compatible path
        let base64 = screenshot.map { ScreenshotCapture.shared.encodeScreenshotToBase64($0) } ?? ""
        let body = buildRequestBody(systemPrompt: systemPrompt, base64: base64, intent: intent, stream: false)

        let endpoint = provider.currentEndpoint
        guard let url = URL(string: endpoint) else {
            throw AIReplyError.requestFailed("Invalid endpoint URL: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        applyAuth(&request)

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw AIReplyError.requestFailed("Failed to build request body")
        }

        let model = provider.currentModel
        print("ContextualReplyManager: \(provider.selectedProvider.displayName) → \(model) @ \(endpoint)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError {
            print("ContextualReplyManager: connection error - \(urlError.localizedDescription)")
            throw AIReplyError.serverNotRunning
        } catch {
            print("ContextualReplyManager: request error - \(error.localizedDescription)")
            throw AIReplyError.serverNotRunning
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIReplyError.requestFailed("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
            print("ContextualReplyManager: HTTP \(httpResponse.statusCode) - \(bodyStr)")
            throw AIReplyError.requestFailed("HTTP \(httpResponse.statusCode)")
        }

        return try parseResponse(data)
    }

    // MARK: - Streaming

    /// Generates a contextual reply with streaming.
    func generateReplyStreaming(screenshot: CGImage?, intent: String, agent: AIAgent? = nil, onChunk: @escaping (String) -> Void) async throws -> String {
        let systemPrompt = buildSystemPrompt(for: agent)

        // Local CLI — no streaming support
        if provider.selectedProvider == .localCLI {
            let userMsg = "User's intent: \(intent)"
            guard let result = await provider.executeCLI(systemPrompt: systemPrompt, userPrompt: userMsg) else {
                throw AIReplyError.emptyResponse
            }
            onChunk(result)
            return result
        }

        // Native Gemini streaming path — SSE with `data: {...}` frames, no [DONE] sentinel.
        if provider.selectedProvider == .gemini {
            let model = provider.currentModel
            let hasVision = AIProviderType.modelSupportsVision(model, provider: .gemini)
            let base64 = screenshot.map { ScreenshotCapture.shared.encodeScreenshotToBase64($0) } ?? ""
            let body = buildGeminiRequestBody(systemPrompt: systemPrompt, base64: base64, intent: intent, hasVision: hasVision)

            guard let url = buildGeminiURL(model: model, stream: true) else {
                throw AIReplyError.requestFailed("Invalid Gemini streaming URL for model \(model)")
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 120
            let key = provider.currentAPIKey
            guard !key.isEmpty else {
                throw AIReplyError.requestFailed("Missing Gemini API key")
            }
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            } catch {
                throw AIReplyError.requestFailed("Failed to build Gemini request body")
            }

            print("ContextualReplyManager: Gemini streaming → \(model)")

            let (bytes, response): (URLSession.AsyncBytes, URLResponse)
            do {
                (bytes, response) = try await URLSession.shared.bytes(for: request)
            } catch {
                throw AIReplyError.serverNotRunning
            }
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw AIReplyError.requestFailed("HTTP error")
            }

            var fullReply = ""
            for try await line in bytes.lines {
                guard let delta = parseGeminiStreamLine(line) else { continue }
                fullReply += delta
                onChunk(fullReply)
            }

            var trimmed = fullReply.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("<think>"), let range = trimmed.range(of: "</think>") {
                trimmed = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            trimmed = substituteTemplateVars(trimmed)
            if trimmed.isEmpty { throw AIReplyError.emptyResponse }
            print("ContextualReplyManager: Gemini streaming complete (\(trimmed.count) chars)")
            return trimmed
        }

        let base64 = screenshot.map { ScreenshotCapture.shared.encodeScreenshotToBase64($0) } ?? ""
        let body = buildRequestBody(systemPrompt: systemPrompt, base64: base64, intent: intent, stream: true)

        let endpoint = provider.currentEndpoint
        guard let url = URL(string: endpoint) else {
            throw AIReplyError.requestFailed("Invalid endpoint URL: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        applyAuth(&request)

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw AIReplyError.requestFailed("Failed to build request body")
        }

        print("ContextualReplyManager: streaming via \(provider.selectedProvider.displayName)")

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            throw AIReplyError.serverNotRunning
        }

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AIReplyError.requestFailed("HTTP error")
        }

        var fullReply = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }

            guard let jsonData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String else { continue }

            fullReply += content
            onChunk(fullReply)
        }

        var trimmed = fullReply.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip thinking tags if present (same as non-streaming path)
        if trimmed.contains("<think>"), let range = trimmed.range(of: "</think>") {
            trimmed = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        trimmed = substituteTemplateVars(trimmed)
        if trimmed.isEmpty { throw AIReplyError.emptyResponse }

        print("ContextualReplyManager: streaming complete (\(trimmed.count) chars)")
        return trimmed
    }

    // MARK: - Server Check

    func checkServerAvailable() async -> Bool {
        await provider.checkServerAvailable()
    }

    // MARK: - Private Helpers

    /// Whether the current model supports vision (screenshot input)
    var currentModelSupportsVision: Bool {
        AIProviderType.modelSupportsVision(provider.currentModel, provider: provider.selectedProvider)
    }

    private func buildRequestBody(systemPrompt: String, base64: String, intent: String, stream: Bool) -> [String: Any] {
        let model = provider.currentModel
        let hasVision = AIProviderType.modelSupportsVision(model, provider: provider.selectedProvider)

        // Build user message — with or without screenshot
        let userContent: Any
        if hasVision && !base64.isEmpty {
            userContent = [
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]],
                ["type": "text", "text": "User's intent: \(intent)"]
            ] as [[String: Any]]
            print("ContextualReplyManager: sending with screenshot (vision mode)")
        } else {
            userContent = "User's intent: \(intent)"
            if !hasVision {
                print("ContextualReplyManager: model '\(model)' may not support vision, sending text-only")
            }
        }

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
            ] as [[String: Any]],
            "stream": stream,
            "max_tokens": 1000,
            "temperature": 0.4,
            "top_p": 0.85,
        ]
        // Local-only sampling params (not supported by cloud APIs)
        if provider.selectedProvider == .ollama || provider.selectedProvider == .custom {
            body["top_k"] = 25
            body["repeat_penalty"] = 1.05
        }
        // Disable thinking/reasoning — these are short pattern-matched replies,
        // not multi-step reasoning. Thinking adds 2-10s latency with no quality
        // win for the reply UX. Non-reasoning models ignore these fields.
        if provider.selectedProvider == .openRouter {
            body["reasoning"] = ["effort": "low", "exclude": true]
        }
        if provider.selectedProvider == .ollama {
            body["think"] = false
        }
        // Custom provider: don't touch — unknown API contract.
        return body
    }

    private func applyAuth(_ request: inout URLRequest) {
        let key = provider.currentAPIKey
        guard !key.isEmpty else {
            print("ContextualReplyManager: WARNING - no API key for \(provider.selectedProvider.rawValue)")
            return
        }
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }

    private func parseResponse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            print("ContextualReplyManager: failed to parse response JSON")
            throw AIReplyError.parseFailed
        }

        var trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip thinking tags if present
        if trimmed.contains("<think>"), let range = trimmed.range(of: "</think>") {
            trimmed = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        trimmed = substituteTemplateVars(trimmed)
        if trimmed.isEmpty { throw AIReplyError.emptyResponse }

        print("ContextualReplyManager: received reply (\(trimmed.count) chars)")
        return trimmed
    }

    /// Belt-and-suspenders fix for any template token that survives into model
    /// output. Some models literal-copy `{sender_name}` or `[Your Name]` from
    /// the prompt examples instead of emitting the substituted name — catch
    /// those here so the user never sees raw template text in their reply.
    private func substituteTemplateVars(_ text: String) -> String {
        let name = AgentManager.shared.senderName
        guard !name.isEmpty else { return text }
        var result = text
        result = result.replacingOccurrences(of: "{sender_name}", with: name)
        result = result.replacingOccurrences(of: "[Your Name]", with: name)
        return result
    }

    /// Builds the full system prompt as three concatenated parts:
    /// 1. Shared header — output rules + context source (vision vs text-only)
    /// 2. Agent body — only the agent's unique specialization
    /// 3. Language rule — derived from the agent's outputLanguage
    ///
    /// Agents no longer reference "screenshot" in their bodies, so there is no
    /// need to regex-rewrite them for text-only models.
    private func buildSystemPrompt(for agent: AIAgent? = nil) -> String {
        let hasVision = currentModelSupportsVision

        // --- 1. Shared header ---
        let contextLine: String = hasVision
            ? "Context: the user provides a screenshot of their current screen and a spoken intent. Use the screenshot to understand the situation; the spoken intent says what to produce."
            : "Context: the user describes what they want via voice. Use their description to understand the situation."
        let header = """
        Output ONLY the requested text. No preamble, no explanations, no "Here is...", no descriptions of what you see.

        \(contextLine)
        """

        // --- 2. Agent body ---
        let agentBody: String
        let outputLanguage: String
        if let agent = agent {
            var body = agent.systemPrompt
            let name = AgentManager.shared.senderName
            let displayName = name.isEmpty ? "[Your Name]" : name
            body = body.replacingOccurrences(of: "{sender_name}", with: displayName)
            print("ContextualReplyManager: agent='\(agent.name)' senderName='\(name)' outputLanguage='\(agent.outputLanguage)' hasVision=\(hasVision) templateStillPresent=\(body.contains("{sender_name}"))")
            agentBody = body
            outputLanguage = agent.outputLanguage
        } else {
            // Legacy fallback when no agent is routed (shouldn't happen post-07-06)
            agentBody = "Generate an appropriate response based on the user's stated intent. Adapt tone and format to the situation."
            outputLanguage = "Match conversation"
        }

        // --- 3. Language rule (single source of truth) ---
        let languageLine: String
        if outputLanguage == "Match conversation" {
            languageLine = hasVision
                ? "IMPORTANT: Match the language present in the screenshot content. The user may speak their intent in a different language — ignore that for language choice."
                : "IMPORTANT: Match the language of the user's intent."
        } else {
            // Explicit language override — phrase emphatically so the model doesn't
            // mirror the screenshot or user-intent language instead.
            languageLine = "IMPORTANT: Write your ENTIRE response in \(outputLanguage). This applies even if the original email/conversation shown in the screenshot or the user's spoken intent is in a different language. Translate as needed — do NOT mirror the source language."
        }
        print("ContextualReplyManager: languageLine='\(languageLine.prefix(80))...'")

        return "\(header)\n\n\(agentBody)\n\n\(languageLine)"
    }

    // MARK: - Native Gemini Helpers

    /// Builds the native Gemini endpoint URL for a given model.
    /// Uses `:generateContent` for non-streaming, `:streamGenerateContent?alt=sse` for streaming.
    private func buildGeminiURL(model: String, stream: Bool) -> URL? {
        let base = "https://generativelanguage.googleapis.com/v1beta/models/\(model)"
        let suffix = stream ? ":streamGenerateContent?alt=sse" : ":generateContent"
        return URL(string: base + suffix)
    }

    /// Builds a native Gemini request body. Maps our standard fields to Google's schema:
    /// - systemPrompt → systemInstruction.parts[].text
    /// - intent (+ optional base64 image) → contents[0].parts
    /// - sampling → generationConfig.{maxOutputTokens, temperature, topP}
    private func buildGeminiRequestBody(systemPrompt: String, base64: String, intent: String, hasVision: Bool) -> [String: Any] {
        var userParts: [[String: Any]] = []
        if hasVision && !base64.isEmpty {
            userParts.append([
                "inlineData": [
                    "mimeType": "image/jpeg",
                    "data": base64,
                ],
            ])
        }
        userParts.append(["text": "User's intent: \(intent)"])

        // Disable thinking for speed — short pattern-matched replies don't
        // benefit from multi-step reasoning. gemini-2.5-pro / 3-pro reject a
        // budget of 0, so fall back to the minimum (128) on those.
        let modelName = provider.currentModel.lowercased()
        let thinkingBudget = (modelName.contains("2.5-pro") || modelName.contains("3-pro")) ? 128 : 0

        return [
            "systemInstruction": [
                "parts": [["text": systemPrompt]],
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": userParts,
                ],
            ] as [[String: Any]],
            "generationConfig": [
                "maxOutputTokens": 1000,
                "temperature": 0.4,
                "topP": 0.85,
                "thinkingConfig": ["thinkingBudget": thinkingBudget],
            ],
        ]
    }

    /// Parses a native Gemini non-streaming response: candidates[0].content.parts[0].text.
    /// Concatenates all text parts in case the model returns multiple (rare but allowed).
    private func parseGeminiResponse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            print("ContextualReplyManager: failed to parse Gemini response JSON")
            throw AIReplyError.parseFailed
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip thinking tags if present (consistent with parseResponse)
        if trimmed.contains("<think>"), let range = trimmed.range(of: "</think>") {
            trimmed = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        trimmed = substituteTemplateVars(trimmed)
        if trimmed.isEmpty { throw AIReplyError.emptyResponse }
        return trimmed
    }

    /// Parses a single SSE line from Gemini streaming response.
    /// Returns the incremental text delta, or nil if the line is not a usable data payload.
    /// Expected format: `data: {"candidates":[{"content":{"parts":[{"text":"..."}]}}]}`.
    private func parseGeminiStreamLine(_ line: String) -> String? {
        guard line.hasPrefix("data: ") else { return nil }
        let payload = String(line.dropFirst(6))
        if payload.isEmpty { return nil }
        guard let jsonData = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }
}
