import SwiftUI

// MARK: - AI Agent Tab

struct AIAgentTab: View {
    @AppStorage("aiReplyEnabled") private var isEnabled = false
    @AppStorage("selectedAIHotkey") private var selectedAIHotkeyRaw = HotkeyOption.fnOption.rawValue
    @AppStorage("selectedHotkey") private var selectedSTTHotkeyRaw = HotkeyOption.leftControlOption.rawValue

    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var providerManager = AIProviderManager.shared
    @State private var connectionStatus: ConnectionStatus = .unknown
    @State private var editingAgent: AIAgent?
    @State private var showAddAgent = false
    @State private var nameSaved = false
    @State private var apiKeyInput = ""
    @State private var apiKeySaved = false

    enum ConnectionStatus { case unknown, checking, connected, failed }

    private var aiAgentHotkey: Binding<HotkeyOption> {
        Binding(
            get: { HotkeyOption(rawValue: selectedAIHotkeyRaw) ?? .fnOption },
            set: { selectedAIHotkeyRaw = $0.rawValue }
        )
    }

    private var sttHotkey: HotkeyOption {
        HotkeyOption(rawValue: selectedSTTHotkeyRaw) ?? .leftControlOption
    }

    private var selectionModeBinding: Binding<AgentSelectionMode> {
        Binding(
            get: { agentManager.selectionMode },
            set: { agentManager.selectionMode = $0 }
        )
    }

    private var manualAgentBinding: Binding<UUID> {
        Binding(
            get: { agentManager.manualAgentId ?? BuiltinAgents.assistantId },
            set: { agentManager.manualAgentId = $0 }
        )
    }

    private var senderNameBinding: Binding<String> {
        Binding(
            get: { agentManager.senderName },
            set: { agentManager.senderName = $0 }
        )
    }

    static let outputLanguageOptions = [
        "Match conversation", "English", "Chinese", "Japanese",
        "Korean", "Spanish", "French", "German",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Section 1: Enable + Agent Mode
            SettingsSection("AI Agent") {
                SettingRow("Enable") {
                    Toggle("", isOn: $isEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
                Text("Hold hotkey to capture screen + speak intent, release to generate a contextual reply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                SettingRow("Agent Selection") {
                    Picker("", selection: selectionModeBinding) {
                        Text("Auto").tag(AgentSelectionMode.auto)
                        Text("Manual").tag(AgentSelectionMode.manual)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }

                if agentManager.selectionMode == .auto {
                    Text("Automatically detects context (email, chat, code) from the active app and screen content.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("Use Agent")
                            .frame(minWidth: 100, alignment: .leading)
                        Spacer()
                        Picker("", selection: manualAgentBinding) {
                            ForEach(agentManager.agents) { agent in
                                Label(agent.name, systemImage: agent.icon).tag(agent.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                }

                Divider()

                SettingRow("Your Name") {
                    HStack(spacing: 6) {
                        TextField("e.g. Jason", text: senderNameBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                            .onSubmit {
                                nameSaved = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                    nameSaved = false
                                }
                            }
                        if nameSaved {
                            HStack(spacing: 2) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Saved")
                                    .foregroundColor(.green)
                            }
                            .font(.caption)
                            .transition(.opacity)
                        }
                    }
                }
                Text("Used for email sign-offs. Press Return to confirm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Section 2: Agent List
            SettingsSection("Agents") {
                ForEach(agentManager.agents) { agent in
                    HStack(spacing: 10) {
                        Image(systemName: agent.icon)
                            .foregroundColor(.accentColor)
                            .frame(width: 20)
                        Text(agent.name)
                            .fontWeight(.medium)
                        Spacer()
                        Text(agent.outputLanguage)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .foregroundStyle(.secondary)
                            .background(.secondary.opacity(0.1), in: Capsule())
                        Button("Edit") {
                            editingAgent = agent
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    .padding(.vertical, 2)
                    if agent.id != agentManager.agents.last?.id {
                        Divider()
                    }
                }

                Divider()

                HStack {
                    Text("\(agentManager.agents.filter { $0.isBuiltin }.count) built-in, \(agentManager.agents.filter { !$0.isBuiltin }.count) custom")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showAddAgent = true
                    } label: {
                        Label("Add Agent", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }

            // Section 3: Activation
            SettingsSection("Activation") {
                SettingRow("AI Agent Hotkey") {
                    HotkeyPicker(selection: aiAgentHotkey, reservedBy: sttHotkey)
                        .frame(width: 220)
                }
                Text("The Record Hotkey (\(sttHotkey.displayName)) is greyed out because one hotkey can't drive two modes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Section 4: AI Provider
            SettingsSection("AI Provider") {
                SettingRow("Provider") {
                    Picker("", selection: $providerManager.selectedProvider) {
                        ForEach(AIProviderType.allCases) { prov in
                            Label(prov.displayName, systemImage: prov.icon).tag(prov)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .onChange(of: providerManager.selectedProvider) { _, newVal in
                        connectionStatus = .unknown
                        if newVal.supportsDynamicModels {
                            Task { await providerManager.fetchModels(for: newVal) }
                        }
                    }
                }

                // Model picker — varies by provider
                providerModelSection

                // API key — for providers that need it
                if providerManager.selectedProvider.requiresAPIKey {
                    providerAPIKeySection
                }

                // Ollama URL config
                if providerManager.selectedProvider == .ollama {
                    Divider()
                    SettingRow("Server URL") {
                        TextField("http://localhost:11434", text: $providerManager.ollamaURL)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }
                }

                // Custom endpoint config
                if providerManager.selectedProvider == .custom {
                    Divider()
                    SettingRow("Endpoint URL") {
                        TextField("http://localhost:8765/v1/...", text: $providerManager.customEndpoint)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }
                    SettingRow("API Key") {
                        HStack(spacing: 6) {
                            SecureField("Optional", text: $apiKeyInput)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                                .onAppear { apiKeyInput = providerManager.apiKey(for: .custom) }
                            Button("Save") {
                                providerManager.setAPIKey(apiKeyInput, for: .custom)
                                apiKeySaved = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { apiKeySaved = false }
                            }
                            .controlSize(.small)
                            if apiKeySaved {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption)
                            }
                        }
                    }
                }

                // Local CLI config
                if providerManager.selectedProvider == .localCLI {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Command").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Menu("Templates") {
                                ForEach(CLITemplate.allCases) { tmpl in
                                    Button(tmpl.rawValue) {
                                        providerManager.cliCommand = tmpl.command
                                    }
                                }
                            }
                            .controlSize(.small)
                        }
                        TextEditor(text: $providerManager.cliCommand)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 50)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                        Text("Available env vars: $ZHIYIN_SYSTEM_PROMPT, $ZHIYIN_USER_PROMPT, $ZHIYIN_FULL_PROMPT")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        SettingRow("Timeout") {
                            Picker("", selection: $providerManager.cliTimeout) {
                                Text("15s").tag(15)
                                Text("30s").tag(30)
                                Text("60s").tag(60)
                                Text("120s").tag(120)
                            }
                            .labelsHidden()
                            .frame(width: 80)
                        }
                    }
                }

                // Vision support warning
                if !AIProviderType.modelSupportsVision(providerManager.currentModel, provider: providerManager.selectedProvider) {
                    Divider()
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text("This model may not support vision. Screenshots will be skipped — the AI Agent will use your voice intent only.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                // Connection test — for all except Local CLI
                if providerManager.selectedProvider != .localCLI {
                    Divider()
                    HStack {
                        Button("Test Connection") {
                            connectionStatus = .checking
                            Task {
                                let ok = await ContextualReplyManager.shared.checkServerAvailable()
                                await MainActor.run {
                                    connectionStatus = ok ? .connected : .failed
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(connectionStatus == .checking)

                        switch connectionStatus {
                        case .unknown: EmptyView()
                        case .checking:
                            ProgressView().scaleEffect(0.7)
                            Text("Checking...").font(.caption).foregroundStyle(.secondary)
                        case .connected:
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text("Connected").font(.caption).foregroundStyle(.green)
                        case .failed:
                            Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                            Text("Not available").font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }

            // Section 5: Tips
            SettingsSection("Tips") {
                Label("Requires Screen Recording permission (System Settings > Privacy)", systemImage: "rectangle.dashed.badge.record")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label("16GB+ RAM recommended (STT model + vision LLM)", systemImage: "memorychip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: $editingAgent) { agent in
            AgentEditSheet(agent: agent, isPresented: $editingAgent)
        }
        .sheet(isPresented: $showAddAgent) {
            AgentAddSheet(isPresented: $showAddAgent)
        }
        .onAppear {
            apiKeyInput = providerManager.apiKey(for: providerManager.selectedProvider)
            if providerManager.selectedProvider.supportsDynamicModels {
                Task { await providerManager.fetchModels(for: providerManager.selectedProvider) }
            }
        }
    }

    // MARK: - Provider Model Picker

    @ViewBuilder
    private var providerModelSection: some View {
        let prov = providerManager.selectedProvider
        if prov == .localCLI {
            EmptyView()
        } else {
            Divider()
            SettingRow("Model") {
                let modelBinding = Binding<String>(
                    get: { providerManager.currentModel },
                    set: { providerManager.setModel($0, for: prov) }
                )

                if prov == .ollama {
                    // Dynamic Ollama models
                    HStack(spacing: 6) {
                        if providerManager.ollamaModels.isEmpty {
                            TextField("e.g. gemma4:e4b", text: modelBinding)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                        } else {
                            Picker("", selection: modelBinding) {
                                ForEach(providerManager.ollamaModels, id: \.self) { m in
                                    Text(m).tag(m)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 160)
                        }
                        Button(action: { Task { await providerManager.fetchModels(for: .ollama) } }) {
                            Image(systemName: "arrow.clockwise").font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                } else if prov == .openRouter {
                    // Dynamic OpenRouter models
                    HStack(spacing: 6) {
                        if providerManager.openRouterModels.isEmpty {
                            TextField("e.g. google/gemma-4-26b-a4b-it:free", text: modelBinding)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                        } else {
                            Picker("", selection: modelBinding) {
                                ForEach(providerManager.openRouterModels, id: \.self) { m in
                                    Text(m).tag(m)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 220)
                        }
                        Button(action: { Task { await providerManager.fetchModels(for: .openRouter) } }) {
                            Image(systemName: "arrow.clockwise").font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                } else if prov == .gemini {
                    // Dynamic Gemini models
                    HStack(spacing: 6) {
                        if providerManager.geminiModels.isEmpty {
                            TextField("e.g. gemini-2.5-flash", text: modelBinding)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                        } else {
                            Picker("", selection: modelBinding) {
                                ForEach(providerManager.geminiModels, id: \.self) { m in
                                    Text(m).tag(m)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 220)
                        }
                        Button(action: { Task { await providerManager.fetchModels(for: .gemini) } }) {
                            Image(systemName: "arrow.clockwise").font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    // Custom — freeform text
                    TextField("Model name", text: modelBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
            }
        }
    }

    // MARK: - Provider API Key

    @ViewBuilder
    private var providerAPIKeySection: some View {
        let prov = providerManager.selectedProvider
        Divider()
        if providerManager.hasAPIKey(for: prov) {
            SettingRow("API Key") {
                HStack(spacing: 6) {
                    Text("••••••••" + String(providerManager.apiKey(for: prov).suffix(4)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Remove") {
                        providerManager.setAPIKey("", for: prov)
                        apiKeyInput = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                }
            }
        } else {
            SettingRow("API Key") {
                HStack(spacing: 6) {
                    SecureField("Enter API key", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    Button("Save") {
                        providerManager.setAPIKey(apiKeyInput, for: prov)
                        apiKeySaved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { apiKeySaved = false }
                    }
                    .controlSize(.small)
                    .disabled(apiKeyInput.isEmpty)
                    if apiKeySaved {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption)
                    }
                }
            }
        }
    }
}
