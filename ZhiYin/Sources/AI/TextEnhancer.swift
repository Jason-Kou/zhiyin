import Foundation

enum EnhanceMode: String, Codable, CaseIterable, Identifiable {
    case grammar, formal, casual, translate
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .grammar: return "Grammar Fix"
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .translate: return "Translate"
        }
    }

    var systemPrompt: String {
        switch self {
        case .grammar:
            return "Fix grammar and punctuation errors in the following Chinese text. Keep the original meaning. Only return the corrected text, nothing else."
        case .formal:
            return "Rewrite the following Chinese text in a formal, professional tone. Add proper punctuation. Only return the rewritten text."
        case .casual:
            return "Rewrite the following Chinese text in a casual, conversational tone. Only return the rewritten text."
        case .translate:
            return "Translate the following Chinese text to English. Only return the translation."
        }
    }
}

class TextEnhancer {
    static let shared = TextEnhancer()

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "aiEnhanceEnabled") }
    }
    @Published var modelName: String {
        didSet { UserDefaults.standard.set(modelName, forKey: "aiEnhanceModel") }
    }
    @Published var enhanceMode: EnhanceMode {
        didSet { UserDefaults.standard.set(enhanceMode.rawValue, forKey: "aiEnhanceMode") }
    }

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: "aiEnhanceEnabled")
        modelName = UserDefaults.standard.string(forKey: "aiEnhanceModel") ?? "qwen3:8b"
        let modeRaw = UserDefaults.standard.string(forKey: "aiEnhanceMode") ?? "grammar"
        enhanceMode = EnhanceMode(rawValue: modeRaw) ?? .grammar
    }

    func enhance(text: String, mode: EnhanceMode? = nil) async -> String {
        let useMode = mode ?? enhanceMode
        let ollamaURL = URL(string: "http://localhost:11434/api/generate")!

        let body: [String: Any] = [
            "model": modelName,
            "prompt": text,
            "system": useMode.systemPrompt,
            "stream": false,
        ]

        var request = URLRequest(url: ollamaURL)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                return fallbackEnhance(text)
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["response"] as? String {
                return result.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            print("Ollama unavailable: \(error.localizedDescription)")
        }

        return fallbackEnhance(text)
    }

    /// Simple rule-based fallback when Ollama is unavailable
    private func fallbackEnhance(_ text: String) -> String {
        var result = text
        // Remove common Chinese filler words
        let fillers = ["嗯", "啊", "呃", "那个", "就是说", "然后呢"]
        for filler in fillers {
            result = result.replacingOccurrences(of: filler, with: "")
        }
        // Clean up double spaces
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
