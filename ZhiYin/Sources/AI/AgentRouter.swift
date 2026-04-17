import Foundation
import AppKit
import CoreGraphics

/// Routes to the appropriate AIAgent using 3-layer detection:
/// 1. BundleId direct match
/// 2. Browser window title keyword match
/// 3. LLM screenshot classification fallback
class AgentRouter {
    static let shared = AgentRouter()

    // MARK: - Layer 1: BundleId → Agent mapping

    private let bundleIdRules: [String: UUID] = [
        // Email clients
        "com.apple.mail": BuiltinAgents.emailId,
        "com.microsoft.Outlook": BuiltinAgents.emailId,
        "com.readdle.smartemail.macos": BuiltinAgents.emailId,
        "com.postbox-inc.postbox": BuiltinAgents.emailId,
        "com.freron.MailMate": BuiltinAgents.emailId,
        "com.canarymail.mac": BuiltinAgents.emailId,
        "com.mimestream.Mimestream": BuiltinAgents.emailId,

        // Chat clients
        "com.tencent.xinWeChat": BuiltinAgents.instantMessageId,
        "com.apple.MobileSMS": BuiltinAgents.instantMessageId,
        "com.tinyspeck.slackmacgap": BuiltinAgents.instantMessageId,
        "com.hnc.Discord": BuiltinAgents.instantMessageId,
        "ru.keepcoder.Telegram": BuiltinAgents.instantMessageId,
        "net.whatsapp.WhatsApp": BuiltinAgents.instantMessageId,
        "com.facebook.archon": BuiltinAgents.instantMessageId,       // Messenger
        "com.microsoft.teams2": BuiltinAgents.instantMessageId,
        "com.skype.skype": BuiltinAgents.instantMessageId,
        "com.lark.Lark": BuiltinAgents.instantMessageId,             // Feishu/Lark
        "com.alibaba.DingTalkMac": BuiltinAgents.instantMessageId,   // DingTalk

        // Code editors
        "com.microsoft.VSCode": BuiltinAgents.assistantId,
        "com.microsoft.VSCodeInsiders": BuiltinAgents.assistantId,
        "dev.zed.Zed": BuiltinAgents.assistantId,
        "com.sublimetext.4": BuiltinAgents.assistantId,
        "com.jetbrains.intellij": BuiltinAgents.assistantId,
        "com.googlecode.iterm2": BuiltinAgents.assistantId,
        "com.apple.Terminal": BuiltinAgents.assistantId,
        "net.kovidgoyal.kitty": BuiltinAgents.assistantId,
        "com.github.wez.wezterm": BuiltinAgents.assistantId,
        "io.alacritty": BuiltinAgents.assistantId,
        "com.cursor.Cursor": BuiltinAgents.assistantId,
    ]

    // MARK: - Layer 2: Browser window title keywords

    private let browserBundleIds: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",    // Arc
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    private let emailTitleKeywords: [String] = [
        "Gmail", "Outlook", "Yahoo Mail", "ProtonMail", "Proton Mail",
        "Zoho Mail", "Mail -", "Inbox -", "Compose -", "Fastmail",
        "iCloud Mail", "Hey.com", "Tutanota",
    ]

    private let chatTitleKeywords: [String] = [
        "Slack", "Discord", "WhatsApp", "Telegram", "Messenger",
        "Microsoft Teams", "WeChat", "Signal", "Skype",
        "Google Chat", "Element", "Matrix", "Zulip",
        "飞书", "钉钉", "Lark",
    ]

    private let codeTitleKeywords: [String] = [
        "GitHub", "GitLab", "Bitbucket", "CodeSandbox", "StackBlitz",
        "Replit", "Stack Overflow", "pull request", "Pull Request",
    ]

    // MARK: - Public API

    /// Select the appropriate agent. Fast path (layers 1-2) is synchronous.
    /// Falls back to LLM classification if needed.
    func selectAgent(screenshot: CGImage? = nil) async -> AIAgent {
        let manager = AgentManager.shared

        // Manual mode: return user-selected agent
        if manager.selectionMode == .manual {
            return manager.manualAgent ?? manager.assistantAgent
        }

        // Auto mode: 3-layer detection
        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleId = frontApp?.bundleIdentifier ?? ""
        let windowTitle = getFrontmostWindowTitle()

        print("AgentRouter: bundleId=\(bundleId) windowTitle=\(windowTitle ?? "nil")")

        // Layer 1: BundleId direct match
        if let agentId = bundleIdRules[bundleId], let agent = manager.agent(for: agentId) {
            print("AgentRouter: Layer 1 match → \(agent.name)")
            return agent
        }

        // Layer 2: Browser window title keywords
        if browserBundleIds.contains(bundleId), let title = windowTitle {
            if let agent = matchWindowTitle(title, manager: manager) {
                print("AgentRouter: Layer 2 match → \(agent.name)")
                return agent
            }
        }

        // Layer 3: LLM screenshot classification
        if let screenshot = screenshot {
            if let agent = await classifyViaLLM(screenshot: screenshot, manager: manager) {
                print("AgentRouter: Layer 3 LLM match → \(agent.name)")
                return agent
            }
        }

        // Fallback: Assistant
        print("AgentRouter: no match, falling back to Assistant")
        return manager.assistantAgent
    }

    // MARK: - Layer 2 Implementation

    private func matchWindowTitle(_ title: String, manager: AgentManager) -> AIAgent? {
        let lowered = title.lowercased()

        for keyword in emailTitleKeywords {
            if lowered.contains(keyword.lowercased()) {
                return manager.agent(for: BuiltinAgents.emailId)
            }
        }
        for keyword in chatTitleKeywords {
            if lowered.contains(keyword.lowercased()) {
                return manager.agent(for: BuiltinAgents.instantMessageId)
            }
        }
        for keyword in codeTitleKeywords {
            if lowered.contains(keyword.lowercased()) {
                return manager.agent(for: BuiltinAgents.assistantId)
            }
        }
        return nil
    }

    // MARK: - Layer 3 Implementation

    private func classifyViaLLM(screenshot: CGImage, manager: AgentManager) async -> AIAgent? {
        let base64 = ScreenshotCapture.shared.encodeScreenshotToBase64(screenshot)
        guard !base64.isEmpty else { return nil }

        let providerManager = AIProviderManager.shared
        guard providerManager.selectedProvider.isOpenAICompatible else { return nil }
        // Gemini ships its own /v1beta/openai/chat/completions shim, but that
        // shim rejects new AQ.* API keys — the main reply path was migrated to
        // the native :generateContent endpoint for that reason. Skip Layer 3
        // entirely for Gemini rather than firing a request that's going to 400
        // and waste the 10s timeout; the caller falls back to Assistant.
        if providerManager.selectedProvider == .gemini {
            print("AgentRouter: skipping Layer 3 LLM classifier for Gemini (use Layer 1/2 or Assistant fallback)")
            return nil
        }
        let endpoint = providerManager.currentEndpoint
        guard let url = URL(string: endpoint) else { return nil }

        let body: [String: Any] = [
            "model": providerManager.currentModel,
            "messages": [
                ["role": "system", "content": "You are a screen context classifier. Look at the screenshot and classify it into exactly ONE category. Reply with a single word only, nothing else."],
                ["role": "user", "content": [
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]],
                    ["type": "text", "text": "Classify this screenshot: email, message, or general? Reply with ONE word only."],
                ] as [[String: Any]]],
            ] as [[String: Any]],
            "stream": false,
            "max_tokens": 10,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        let apiKey = providerManager.currentAPIKey
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else { return nil }

            let category = content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased()
            print("AgentRouter: LLM classified as '\(category)'")

            switch category {
            case "email": return manager.agent(for: BuiltinAgents.emailId)
            case "message", "im", "chat": return manager.agent(for: BuiltinAgents.instantMessageId)
            default: return nil  // fall through to Assistant (covers "general", "code", etc.)
            }
        } catch {
            print("AgentRouter: LLM classification failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Window Title Helper

    private func getFrontmostWindowTitle() -> String? {
        // Use Accessibility API to get window title
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier
        let appRef = AXUIElementCreateApplication(pid)

        var windowValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &windowValue) == .success else {
            return nil
        }

        // swiftlint:disable:next force_cast — AXUIElementCopyAttributeValue always returns AXUIElement for kAXFocusedWindowAttribute
        let windowElement = windowValue as! AXUIElement
        var titleValue: AnyObject?
        guard AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleValue) == .success else {
            return nil
        }

        return titleValue as? String
    }
}
