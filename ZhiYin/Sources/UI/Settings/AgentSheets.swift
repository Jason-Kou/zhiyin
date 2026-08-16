import SwiftUI

// MARK: - Agent Edit Sheet

struct AgentEditSheet: View {
    let agent: AIAgent
    @Binding var isPresented: AIAgent?
    @State private var name: String
    @State private var icon: String
    @State private var outputLanguage: String
    @State private var systemPrompt: String
    @ObservedObject private var manager = AgentManager.shared

    init(agent: AIAgent, isPresented: Binding<AIAgent?>) {
        self.agent = agent
        self._isPresented = isPresented
        self._name = State(initialValue: agent.name)
        self._icon = State(initialValue: agent.icon)
        self._outputLanguage = State(initialValue: agent.outputLanguage)
        self._systemPrompt = State(initialValue: agent.systemPrompt)
    }

    private let iconOptions = [
        "envelope", "bubble.left", "chevron.left.forwardslash.chevron.right",
        "sparkles", "doc.text", "globe", "person.crop.circle",
        "briefcase", "graduationcap", "translate",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Agent: \(agent.name)")
                .font(.headline)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .disabled(agent.isBuiltin)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Icon").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $icon) {
                        ForEach(iconOptions, id: \.self) { ic in
                            Image(systemName: ic).tag(ic)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 80)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Output Language").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $outputLanguage) {
                    ForEach(AIAgentTab.outputLanguageOptions, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("System Prompt").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $systemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 180)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.quaternary, lineWidth: 1)
                    )
            }

            HStack {
                if agent.isBuiltin {
                    Button("Reset to Default") {
                        systemPrompt = agent.defaultPrompt
                    }
                    .disabled(systemPrompt == agent.defaultPrompt)
                } else {
                    Button("Delete Agent") {
                        manager.remove(id: agent.id)
                        isPresented = nil
                    }
                    .foregroundColor(.red)
                }

                Spacer()

                Button("Cancel") {
                    isPresented = nil
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    var updated = agent
                    updated.name = name
                    updated.icon = icon
                    updated.outputLanguage = outputLanguage
                    updated.systemPrompt = systemPrompt
                    manager.update(updated)
                    isPresented = nil
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

// MARK: - Agent Add Sheet

struct AgentAddSheet: View {
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var icon = "sparkles"
    @State private var outputLanguage = "Match conversation"
    @State private var systemPrompt = "You are a helpful assistant. The user shows you a screenshot and tells you their intent. Generate an appropriate response based on the context. Output ONLY the response text."
    @ObservedObject private var manager = AgentManager.shared

    private let iconOptions = [
        "envelope", "bubble.left", "chevron.left.forwardslash.chevron.right",
        "sparkles", "doc.text", "globe", "person.crop.circle",
        "briefcase", "graduationcap", "translate",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Agent")
                .font(.headline)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("e.g. Translator", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Icon").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $icon) {
                        ForEach(iconOptions, id: \.self) { ic in
                            Image(systemName: ic).tag(ic)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 80)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Output Language").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $outputLanguage) {
                    ForEach(AIAgentTab.outputLanguageOptions, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("System Prompt").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $systemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 140)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.quaternary, lineWidth: 1)
                    )
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    let agent = AIAgent(
                        id: UUID(),
                        name: name,
                        icon: icon,
                        systemPrompt: systemPrompt,
                        outputLanguage: outputLanguage,
                        isBuiltin: false,
                        defaultPrompt: systemPrompt
                    )
                    manager.add(agent)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}
