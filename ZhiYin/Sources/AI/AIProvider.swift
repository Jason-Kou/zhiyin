import Foundation
import Security

// MARK: - AI Provider

enum AIProviderType: String, Codable, CaseIterable, Identifiable {
    /// Vision-language inference inside ZhiYin's own Python server. No install,
    /// no endpoint, no API key — the model downloads itself the way the speech
    /// model already does. Every other provider needs the user to stand up a
    /// server or hold an account first, which is where most people stop.
    case builtin
    case ollama
    case openRouter
    case gemini
    case localCLI
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .builtin: return "Built-in (local)"
        case .ollama: return "Ollama"
        case .openRouter: return "OpenRouter"
        case .gemini: return "Gemini"
        case .localCLI: return "Local CLI"
        case .custom: return "Custom"
        }
    }

    var icon: String {
        switch self {
        case .builtin: return "sparkles.rectangle.stack"
        case .ollama: return "desktopcomputer"
        case .openRouter: return "globe"
        case .gemini: return "sparkle"
        case .localCLI: return "terminal"
        case .custom: return "server.rack"
        }
    }

    var defaultEndpoint: String {
        switch self {
        // Served by the bundled STT server, whose port is fixed.
        case .builtin: return "http://127.0.0.1:17760/v1/chat/completions"
        case .ollama: return "http://localhost:11434/v1/chat/completions"
        case .openRouter: return "https://openrouter.ai/api/v1/chat/completions"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        case .localCLI: return ""
        case .custom: return "http://localhost:8765/v1/chat/completions"
        }
    }

    var defaultModel: String {
        switch self {
        case .builtin: return "mlx-community/Qwen3-VL-8B-Instruct-4bit"
        case .ollama: return "gemma4:e4b"
        // Paid but dependable. The former default, gemma-4 :free, sat in
        // OpenRouter's free-tier queue indefinitely — a request that never
        // returns is worse than one that costs a tenth of a cent.
        case .openRouter: return "google/gemini-3.7-flash"
        case .gemini: return "gemini-2.5-flash-lite"
        case .localCLI: return ""
        case .custom: return "gemma4-e4b"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .builtin, .ollama, .localCLI: return false
        case .openRouter, .gemini: return true
        case .custom: return false // optional
        }
    }

    /// Whether the model list should be fetched from the server
    var supportsDynamicModels: Bool {
        switch self {
        case .ollama, .openRouter, .gemini: return true
        default: return false
        }
    }

    /// Whether this provider uses OpenAI-compatible chat completions API
    var isOpenAICompatible: Bool {
        switch self {
        case .localCLI: return false
        default: return true
        }
    }

    /// Known vision-capable models (for UI hints and fallback logic)
    static let knownVisionModels: Set<String> = [
        // Gemma 4 (all multimodal)
        "gemma4:e4b", "gemma4:31b-cloud", "gemma4-e4b",
        // Gemini (all support vision)
        "gemini-3.1-pro-preview", "gemini-3-flash-preview", "gemini-3.1-flash-lite-preview",
        "gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite",
    ]

    /// Keywords that indicate a model likely supports vision.
    ///
    /// "qwen3.5" used to be on this list and was wrong in a way that cost real
    /// debugging time: Qwen3.5 is a text model, and Ollama's /api/show even
    /// advertises `vision` in its capabilities, but asked about an image it
    /// answers "I cannot see the image directly because I am a text-based AI
    /// model". ZhiYin would attach a screenshot anyway, and the model would burn
    /// its whole budget reasoning about a picture it could not see and return an
    /// empty reply. A false positive here is worse than a false negative — the
    /// latter merely sends text.
    ///
    /// Qwen's vision models are the separate `-VL-` line, matched below.
    static let visionKeywords: [String] = [
        "gemma4", "gemini", "gpt-4o", "gpt-4-vision", "claude-3", "claude-sonnet", "claude-opus",
        "llava", "vision", "multimodal", "moondream", "pixtral", "minicpm-v", "internvl",
    ]

    /// Vision variants are marked with a delimited "vl" — qwen3-vl, qwen2.5-vl,
    /// InternVL. Matched separately because a bare "vl" substring would also hit
    /// unrelated names.
    private static func hasVLMarker(_ lower: String) -> Bool {
        let delimiters: Set<Character> = ["-", "_", ".", ":", "/", " "]
        var idx = lower.startIndex
        while let r = lower.range(of: "vl", range: idx..<lower.endIndex) {
            let beforeOK = r.lowerBound == lower.startIndex
                || delimiters.contains(lower[lower.index(before: r.lowerBound)])
            let afterOK = r.upperBound == lower.endIndex
                || delimiters.contains(lower[r.upperBound])
            if beforeOK && afterOK { return true }
            idx = r.upperBound
        }
        return false
    }

    /// Check if a specific model likely supports vision
    static func modelSupportsVision(_ model: String, provider: AIProviderType) -> Bool {
        // Gemini: all models support vision
        if provider == .gemini { return true }
        // Local CLI: no image support
        if provider == .localCLI { return false }
        // Check known list
        if knownVisionModels.contains(model) { return true }
        // Check keywords
        let lower = model.lowercased()
        if hasVLMarker(lower) { return true }
        // Separator-insensitive: providers spell the same family three ways —
        // Ollama says "gemma4:e4b", OpenRouter "google/gemma-4-31b-it:free".
        // A literal list can only ever match the spellings someone remembered
        // to add; this is the third naming-mismatch bug in this function.
        let separators = Set("-_. :/")
        let normalized = String(lower.filter { !separators.contains($0) })
        return visionKeywords.contains { kw in
            normalized.contains(String(kw.filter { !separators.contains($0) }))
        }
    }
}

// MARK: - Local CLI Templates

enum CLITemplate: String, CaseIterable, Identifiable {
    case claude = "Claude Code"
    case codex = "Codex CLI"
    case custom = "Custom Command"

    var id: String { rawValue }

    var command: String {
        switch self {
        case .claude:
            return "claude -p \"$ZHIYIN_FULL_PROMPT\""
        case .codex:
            return "TMPFILE=$(mktemp) && codex exec --skip-git-repo-check --output-last-message \"$TMPFILE\" \"$ZHIYIN_FULL_PROMPT\" > /dev/null 2>&1 && cat \"$TMPFILE\" && rm \"$TMPFILE\""
        case .custom:
            return "echo \"$ZHIYIN_USER_PROMPT\" | /path/to/your/tool"
        }
    }
}

// MARK: - Keychain Helper

private enum KeychainHelper {
    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.zhiyin.app.apikeys",
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.zhiyin.app.apikeys",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.zhiyin.app.apikeys",
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - AI Provider Manager

class AIProviderManager: ObservableObject {
    static let shared = AIProviderManager()

    @Published var selectedProvider: AIProviderType {
        didSet { UserDefaults.standard.set(selectedProvider.rawValue, forKey: "aiProviderType") }
    }

    // Per-provider model selection
    @Published var selectedModels: [String: String] {
        didSet { UserDefaults.standard.set(selectedModels, forKey: "aiProviderModels") }
    }

    // Ollama server URL (configurable)
    @Published var ollamaURL: String {
        didSet { UserDefaults.standard.set(ollamaURL, forKey: "aiOllamaURL") }
    }

    // Custom endpoint URL
    @Published var customEndpoint: String {
        didSet { UserDefaults.standard.set(customEndpoint, forKey: "aiCustomEndpoint") }
    }

    // Local CLI command
    @Published var cliCommand: String {
        didSet { UserDefaults.standard.set(cliCommand, forKey: "aiCLICommand") }
    }

    // Local CLI timeout (seconds)
    @Published var cliTimeout: Int {
        didSet { UserDefaults.standard.set(cliTimeout, forKey: "aiCLITimeout") }
    }

    // Dynamic model lists (fetched from server)
    @Published var ollamaModels: [String] = []
    @Published var openRouterModels: [String] = []
    @Published var geminiModels: [String] = [
        "gemini-3.1-pro-preview",
        "gemini-3-flash-preview",
        "gemini-3.1-flash-lite-preview",
        "gemini-2.5-pro",
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite",
    ]

    init() {
        let provRaw = UserDefaults.standard.string(forKey: "aiProviderType") ?? "custom"
        selectedProvider = AIProviderType(rawValue: provRaw) ?? .custom
        selectedModels = (UserDefaults.standard.dictionary(forKey: "aiProviderModels") as? [String: String]) ?? [:]
        ollamaURL = UserDefaults.standard.string(forKey: "aiOllamaURL") ?? "http://localhost:11434"
        customEndpoint = UserDefaults.standard.string(forKey: "aiCustomEndpoint")
            ?? (UserDefaults.standard.string(forKey: "aiReplyEndpoint") ?? "http://localhost:8765/v1/chat/completions")
        cliCommand = UserDefaults.standard.string(forKey: "aiCLICommand") ?? CLITemplate.claude.command
        cliTimeout = UserDefaults.standard.integer(forKey: "aiCLITimeout")
        if cliTimeout == 0 { cliTimeout = 30 }

        // Migrate: if no model set for custom, use legacy aiReplyModel
        if selectedModels["custom"] == nil {
            let legacy = UserDefaults.standard.string(forKey: "aiReplyModel") ?? "gemma4-e4b"
            selectedModels["custom"] = legacy
        }
    }

    // MARK: - Current Config

    /// The endpoint URL for the current provider
    var currentEndpoint: String {
        switch selectedProvider {
        // ZhiYin's own server; the port is fixed and never user-configurable.
        case .builtin: return AIProviderType.builtin.defaultEndpoint
        case .ollama: return ollamaURL + "/v1/chat/completions"
        case .openRouter: return AIProviderType.openRouter.defaultEndpoint
        // NOTE: .gemini is special-cased in ContextualReplyManager and uses the native
        // `/v1beta/models/{model}:generateContent` endpoint. This OpenAI-compat URL is
        // kept only for UI display / backwards-compat; the network path ignores it.
        case .gemini: return AIProviderType.gemini.defaultEndpoint
        case .localCLI: return ""
        case .custom: return customEndpoint
        }
    }

    /// The model name for the current provider
    var currentModel: String {
        selectedModels[selectedProvider.rawValue] ?? selectedProvider.defaultModel
    }

    /// Set model for a provider
    func setModel(_ model: String, for provider: AIProviderType) {
        selectedModels[provider.rawValue] = model
    }

    // MARK: - API Keys (Keychain)

    func apiKey(for provider: AIProviderType) -> String {
        KeychainHelper.load(key: "zhiyin_\(provider.rawValue)_apikey") ?? ""
    }

    func setAPIKey(_ key: String, for provider: AIProviderType) {
        if key.isEmpty {
            KeychainHelper.delete(key: "zhiyin_\(provider.rawValue)_apikey")
        } else {
            KeychainHelper.save(key: "zhiyin_\(provider.rawValue)_apikey", value: key)
        }
        objectWillChange.send()
    }

    func hasAPIKey(for provider: AIProviderType) -> Bool {
        !apiKey(for: provider).isEmpty
    }

    /// The API key for the current provider (empty string if none)
    var currentAPIKey: String {
        apiKey(for: selectedProvider)
    }

    // MARK: - Dynamic Model Fetching

    func fetchModels(for provider: AIProviderType) async {
        switch provider {
        case .ollama:
            await fetchOllamaModels()
        case .openRouter:
            await fetchOpenRouterModels()
        case .gemini:
            await fetchGeminiModels()
        default:
            break
        }
    }

    private func fetchOllamaModels() async {
        guard let url = URL(string: ollamaURL + "/api/tags") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                let names = models.compactMap { $0["name"] as? String }.sorted()
                await MainActor.run { self.ollamaModels = names }
            }
        } catch {
            print("AIProviderManager: failed to fetch Ollama models: \(error.localizedDescription)")
        }
    }

    private func fetchOpenRouterModels() async {
        guard let url = URL(string: "https://openrouter.ai/api/v1/models") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let key = apiKey(for: .openRouter)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["data"] as? [[String: Any]] {
                let ids = models.compactMap { $0["id"] as? String }
                // Show free models first, then paid
                let free = ids.filter { $0.contains(":free") }.sorted()
                let paid = ids.filter { !$0.contains(":free") }.sorted()
                await MainActor.run { self.openRouterModels = free + paid }
            }
        } catch {
            print("AIProviderManager: failed to fetch OpenRouter models: \(error.localizedDescription)")
        }
    }

    private func fetchGeminiModels() async {
        let key = apiKey(for: .gemini)
        guard !key.isEmpty else {
            print("AIProviderManager: no Gemini API key, skipping model fetch")
            return
        }
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=100") else { return }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 10
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                let names = models.compactMap { model -> String? in
                    guard let name = model["name"] as? String,
                          let methods = model["supportedGenerationMethods"] as? [String],
                          methods.contains("generateContent") else { return nil }
                    // "models/gemini-2.5-flash" → "gemini-2.5-flash"
                    return name.replacingOccurrences(of: "models/", with: "")
                }.sorted()
                await MainActor.run { self.geminiModels = names }
                print("AIProviderManager: fetched \(names.count) Gemini models")
            }
        } catch {
            print("AIProviderManager: failed to fetch Gemini models: \(error.localizedDescription)")
        }
    }

    // MARK: - Server Availability Check

    func checkServerAvailable() async -> Bool {
        guard selectedProvider.isOpenAICompatible else { return true }

        let endpoint = currentEndpoint
        guard let baseURL = URL(string: endpoint),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return false
        }

        // For Ollama, check /api/tags; for others check /v1/models or just the endpoint
        if selectedProvider == .ollama {
            guard let url = URL(string: ollamaURL + "/api/tags") else { return false }
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            do {
                let (_, resp) = try await URLSession.shared.data(for: request)
                return (resp as? HTTPURLResponse)?.statusCode == 200
            } catch { return false }
        }

        if selectedProvider == .gemini {
            // Native Gemini ListModels — OpenAI-compat /v1/models + Bearer fails
            // for new AQ.* format keys (401 UNAUTHENTICATED).
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1") else { return false }
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            let key = currentAPIKey
            guard !key.isEmpty else { return false }
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            do {
                let (_, resp) = try await URLSession.shared.data(for: request)
                return (resp as? HTTPURLResponse)?.statusCode == 200
            } catch { return false }
        }

        components.path = "/v1/models"
        guard let modelsURL = components.url else { return false }
        var request = URLRequest(url: modelsURL)
        request.timeoutInterval = 3
        let key = currentAPIKey
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, resp) = try await URLSession.shared.data(for: request)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    // MARK: - Local CLI Execution

    func executeCLI(systemPrompt: String, userPrompt: String) async -> String? {
        let command = cliCommand
        guard !command.isEmpty else { return nil }

        print("AIProviderManager CLI: executing command: \(command.prefix(80))...")
        print("AIProviderManager CLI: userPrompt: \(userPrompt.prefix(100))...")
        print("AIProviderManager CLI: timeout: \(cliTimeout)s")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.environment = ProcessInfo.processInfo.environment
        process.environment?["ZHIYIN_SYSTEM_PROMPT"] = systemPrompt
        process.environment?["ZHIYIN_USER_PROMPT"] = userPrompt
        process.environment?["ZHIYIN_FULL_PROMPT"] = """
        <SYSTEM_PROMPT>
        \(systemPrompt)
        </SYSTEM_PROMPT>

        <USER_PROMPT>
        \(userPrompt)
        </USER_PROMPT>
        """

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()

            // Read pipe data BEFORE waitUntilExit to avoid deadlock when buffer fills
            let stdoutData: Data
            let stderrData: Data
            let timeout = cliTimeout
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            // Timeout — terminate if still running after pipes are drained
            let deadline = DispatchTime.now() + .seconds(timeout)
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if process.isRunning {
                    print("AIProviderManager CLI: timeout after \(timeout)s, terminating")
                    process.terminate()
                }
            }

            process.waitUntilExit()
            let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            print("AIProviderManager CLI: exit code \(process.terminationStatus), stdout \(stdout.count) chars, stderr \(stderr.count) chars")
            if !stderr.isEmpty {
                print("AIProviderManager CLI stderr: \(stderr.prefix(300))")
            }

            // Try stdout first, fall back to stderr (some tools write to stderr)
            let output = stdout.isEmpty ? stderr : stdout
            return output.isEmpty ? nil : output
        } catch {
            print("AIProviderManager: CLI execution failed: \(error.localizedDescription)")
            return nil
        }
    }
}
