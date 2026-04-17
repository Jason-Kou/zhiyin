import Foundation

// MARK: - Agent Selection Mode

enum AgentSelectionMode: String, Codable {
    case auto
    case manual
}

// MARK: - AI Agent

struct AIAgent: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var icon: String
    var systemPrompt: String
    var outputLanguage: String
    var isBuiltin: Bool
    var defaultPrompt: String

    /// Create a built-in agent with matching default prompt
    static func builtin(id: UUID = UUID(), name: String, icon: String, prompt: String, outputLanguage: String = "Match conversation") -> AIAgent {
        AIAgent(id: id, name: name, icon: icon, systemPrompt: prompt, outputLanguage: outputLanguage, isBuiltin: true, defaultPrompt: prompt)
    }

    /// Reset prompt to factory default
    mutating func resetToDefault() {
        systemPrompt = defaultPrompt
    }
}

// MARK: - Built-in Agent Defaults

enum BuiltinAgents {
    // NOTE: agent prompts contain ONLY the agent's unique specialization.
    // Shared rules (output-only, context source, language rule) are composed
    // at runtime in ContextualReplyManager.buildSystemPrompt so they can adapt
    // to vision vs text-only models without per-agent regex rewrites.

    static let emailPrompt = """
    Write clear, natural emails that match the context.

    Format (always):
    Hi [recipient's first name or "there"],

    [Optional one-line polite opening for business / first-contact emails]
    [Body — 2-4 sentences, well-structured]

    Thank you [brief closing phrase when requesting].

    Best regards,
    {sender_name}

    Style:
    - Fluent and natural, never robotic.
    - Business / first-contact / vendor outreach: polite and formal — open with a short pleasantry such as "I hope this email finds you well." or "Hope you've been doing well." on its own line before the body.
    - Colleague replies / ongoing threads / casual: skip the opening pleasantry, go straight to the body.
    - Business outreach: use "we" instead of "I" when appropriate.
    - Break multi-point requests into short sentences or a short list.
    - Greeting line: pick the most specific option available, in priority order:
      1. If a real person's name is visible (From field like "Sarah Wang <...>", signature, or thread context) → use their first name → "Hi Sarah,"
      2. If the user names the recipient in their voice intent → use that name
      3. If only a company / organization / team is visible (e.g., a noreply or general support address like "Neural Architects (noreply@skool.com)") → "Hi [Company] team," using the company/org name
      4. If nothing identifies a recipient → "Hi there,"
    - Never add subject lines, email headers, or separators.
    - CRITICAL sign-off rule: always end with a sign-off line followed by {sender_name} on its very next line. The sign-off must match the language you are writing the reply in — NOT the original email's language. So: "Best regards," if your reply is in English, "祝好，" if your reply is in Chinese, "よろしくお願いいたします。" if in Japanese, "Cordialement," if in French, etc. NEVER drop {sender_name}, even when replying in a language where a signature line feels unusual.

    Examples:

    User says "ask David about ergonomic office chair pricing and MOQ, need quantity discount":
    Hi David,

    I hope this email finds you well.

    We are interested in your ergonomic office chairs. Could you share the pricing, minimum order quantity, and any quantity-based discounts available?

    Thank you — we look forward to hearing from you.

    Best regards,
    {sender_name}

    User says "ask Acme to expedite the 8 demo units for Contoso before the Q2 expo":
    Hi [name],

    Hope you've been doing well.

    We have sent the 8-unit demo list to Contoso today. Could you arrange the shipment as soon as possible so the units arrive in time for the Q2 expo?

    Thank you — looking forward to your confirmation.

    Best regards,
    {sender_name}

    User says "ask Sarah when to drop off the kid and where to park":
    Hi Sarah,

    Could you let me know what time we can drop off our child and where we should park?

    Thanks in advance!

    Best regards,
    {sender_name}

    User says "tell him I'm free next Tuesday":
    Hi [name],

    I'm free next Tuesday — let me know what time works for you.

    Best regards,
    {sender_name}

    User says "reply to the Skool team — thank them for the course info and ask about pricing and how long course access stays valid":
    Hi Skool team,

    I hope this email finds you well.

    Thank you for the information about your courses! Could you share the pricing and let me know how long course access remains valid after registration?

    Thank you — looking forward to your reply.

    Best regards,
    {sender_name}

    User says "回复 Li 老师，约下周三下午三点在会议室讨论项目进度":
    Li 老师，您好，

    希望您一切都好。

    我想和您约下周三下午三点在会议室讨论一下项目进度，请问方便吗？

    谢谢！

    祝好，
    {sender_name}
    """

    static let instantMessagePrompt = """
    Generate short, direct instant-message replies — the kind you'd send on
    iMessage, WeChat, Slack DM, Discord, or similar.

    Style:
    - Brief: 1-2 sentences, often one line. Never an email-style paragraph.
    - Direct: no "just following up", no "let me know if you need anything".
    - Match the thread's existing tone — casual if casual, terse if work.
    - No greeting or sign-off. IMs don't have them.
    - Emoji and abbreviations are fine when the thread uses them.

    Examples:

    User says "tell her I'll be 10 min late":
    Running 10 min late, sorry!

    User says "say yes I can do the call at 3pm":
    Yeah 3pm works.

    User says "ask him if the file was sent":
    Did you send the file?

    User says "thank her for the quick review":
    Thanks for the quick turnaround!
    """

    static let assistantPrompt = """
    Generate whatever text the user asks for, adapted to the context.

    Style:
    - Forms / input fields: only the text to fill in, no labels or preamble.
    - Documents / content: match the surrounding format.
    - Notes / journal / casual writing: conversational tone.
    """

    /// Stable UUIDs for built-in agents so they survive serialization round-trips.
    /// `instantMessageId` kept equal to the legacy chat UUID so users who had
    /// the Chat agent seamlessly become Instant Message users after migration.
    static let emailId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let instantMessageId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let assistantId = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    /// Legacy UUID for the Code agent that was removed in the agent
    /// consolidation. Kept as a const so AgentManager.load() can detect
    /// and migrate stored data that still references it.
    static let legacyCodeId = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    static let all: [AIAgent] = [
        .builtin(id: emailId, name: "Email", icon: "envelope", prompt: emailPrompt),
        .builtin(id: instantMessageId, name: "Instant Message", icon: "bubble.left", prompt: instantMessagePrompt),
        .builtin(id: assistantId, name: "Assistant", icon: "sparkles", prompt: assistantPrompt),
    ]
}

// MARK: - Agent Manager

class AgentManager: ObservableObject {
    static let shared = AgentManager()

    @Published var agents: [AIAgent] = []
    @Published var selectionMode: AgentSelectionMode {
        didSet { UserDefaults.standard.set(selectionMode.rawValue, forKey: "agentSelectionMode") }
    }
    @Published var manualAgentId: UUID? {
        didSet { UserDefaults.standard.set(manualAgentId?.uuidString ?? "", forKey: "manualAgentId") }
    }
    @Published var senderName: String {
        didSet { UserDefaults.standard.set(senderName, forKey: "agentSenderName") }
    }

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ZhiYin")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("agents.json")

        let modeRaw = UserDefaults.standard.string(forKey: "agentSelectionMode") ?? "auto"
        selectionMode = AgentSelectionMode(rawValue: modeRaw) ?? .auto

        let idStr = UserDefaults.standard.string(forKey: "manualAgentId") ?? ""
        manualAgentId = UUID(uuidString: idStr)

        senderName = UserDefaults.standard.string(forKey: "agentSenderName") ?? ""

        load()
    }

    // MARK: - Lookup

    func agent(for id: UUID) -> AIAgent? {
        agents.first { $0.id == id }
    }

    var manualAgent: AIAgent? {
        guard let id = manualAgentId else { return nil }
        return agent(for: id)
    }

    var assistantAgent: AIAgent {
        agent(for: BuiltinAgents.assistantId) ?? BuiltinAgents.all.last!
    }

    // MARK: - CRUD

    func update(_ agent: AIAgent) {
        if let idx = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[idx] = agent
            save()
        }
    }

    func add(_ agent: AIAgent) {
        agents.append(agent)
        save()
    }

    func remove(at offsets: IndexSet) {
        // Don't delete built-in agents
        let toRemove = offsets.filter { !agents[$0].isBuiltin }
        agents.remove(atOffsets: IndexSet(toRemove))
        save()
    }

    func remove(id: UUID) {
        guard let idx = agents.firstIndex(where: { $0.id == id && !$0.isBuiltin }) else { return }
        agents.remove(at: idx)
        save()
    }

    // MARK: - Persistence

    func save() {
        guard let data = try? JSONEncoder().encode(agents) else { return }
        try? data.write(to: fileURL)
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([AIAgent].self, from: data) {
            agents = decoded
            var needsSave = false

            // Migration: legacy Code agent was removed in the agent
            // consolidation. If the user never customized it, drop it silently.
            // If they did customize, demote to a regular (non-built-in) custom
            // agent so their work isn't lost.
            if let codeIdx = agents.firstIndex(where: { $0.id == BuiltinAgents.legacyCodeId }) {
                let saved = agents[codeIdx]
                if saved.systemPrompt == saved.defaultPrompt {
                    agents.remove(at: codeIdx)
                } else {
                    agents[codeIdx].isBuiltin = false
                }
                needsSave = true
            }
            // If the user had the legacy Code agent pinned as their Manual
            // selection, clear it so they fall back to Assistant.
            if manualAgentId == BuiltinAgents.legacyCodeId
                && !agents.contains(where: { $0.id == BuiltinAgents.legacyCodeId }) {
                manualAgentId = nil
            }

            for builtin in BuiltinAgents.all {
                if let idx = agents.firstIndex(where: { $0.id == builtin.id }) {
                    // Sync built-in agent: update defaultPrompt from code,
                    // and if user hasn't customized the prompt, also refresh
                    // the live systemPrompt + display name + icon (the Chat →
                    // Instant Message rename rides this path).
                    let saved = agents[idx]
                    if saved.defaultPrompt != builtin.defaultPrompt {
                        agents[idx].defaultPrompt = builtin.defaultPrompt
                        if saved.systemPrompt == saved.defaultPrompt {
                            agents[idx].systemPrompt = builtin.defaultPrompt
                            agents[idx].name = builtin.name
                            agents[idx].icon = builtin.icon
                        }
                        needsSave = true
                    }
                } else {
                    // New built-in agent added in app update
                    agents.append(builtin)
                    needsSave = true
                }
            }
            if needsSave { save() }
        } else {
            // First launch: initialize with built-in agents
            agents = BuiltinAgents.all
            save()
        }
    }
}
