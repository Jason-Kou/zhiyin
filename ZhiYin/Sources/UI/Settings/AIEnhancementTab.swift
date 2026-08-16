import SwiftUI

// MARK: - AI Enhancement Tab

struct AIEnhancementTab: View {
    @AppStorage("aiEnhanceEnabled") private var isEnabled = false
    @AppStorage("aiEnhanceModel") private var modelName = "qwen3:8b"
    @AppStorage("aiEnhanceMode") private var modeRaw = "grammar"

    private var selectedMode: Binding<EnhanceMode> {
        Binding(
            get: { EnhanceMode(rawValue: modeRaw) ?? .grammar },
            set: { modeRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("AI Text Enhancement") {
                SettingRow("Auto-enhance") {
                    Toggle("", isOn: $isEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }

                Divider()

                SettingRow("Mode") {
                    Picker("", selection: selectedMode) {
                        ForEach(EnhanceMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }

                Divider()

                SettingRow("Ollama Model") {
                    TextField("", text: $modelName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
            }

            SettingsSection("Tips") {
                Label("Requires Ollama running on port 11434", systemImage: "server.rack")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label("⌘E to enhance selected/clipboard text anytime", systemImage: "keyboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label("Falls back to simple rules if Ollama is unavailable", systemImage: "arrow.uturn.backward")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
