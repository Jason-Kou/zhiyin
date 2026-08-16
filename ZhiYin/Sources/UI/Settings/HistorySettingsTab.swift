import SwiftUI

// MARK: - History Tab

struct HistorySettingsTab: View {
    @AppStorage("saveHistoryEnabled") private var saveHistory = true
    @AppStorage("historyRetentionDays") private var retentionDays = 30
    @State private var recordingCount = 0
    @State private var storageSize = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("Transcription History") {
                SettingRow("Save History") {
                    Toggle("", isOn: $saveHistory)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
                Text("Automatically save transcriptions and audio recordings for later review.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                SettingRow("Auto-delete after") {
                    Picker("", selection: $retentionDays) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("Never").tag(0)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                .disabled(!saveHistory)
                Text(retentionDays == 0
                     ? "Recordings are kept indefinitely."
                     : "Old recordings and transcriptions are automatically removed on launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection("Storage") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(recordingCount) recordings")
                            .font(.callout)
                        Text(storageSize)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        let stats = HistoryStore.storageStats()
                        let alert = NSAlert()
                        alert.messageText = "Delete all history?"
                        alert.informativeText = "This permanently removes \(stats.count) recordings (\(String(format: "%.1f", Double(stats.bytes) / 1_000_000)) MB) and every transcription. This cannot be undone."
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "Delete All")
                        alert.addButton(withTitle: "Cancel")
                        if alert.runModal() == .alertFirstButtonReturn {
                            HistoryStore.shared.deleteAll()
                            refreshStats()
                        }
                    } label: {
                        Text("Delete All\u{2026}")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(recordingCount == 0)
                    Button("Show in Finder") {
                        let path = HistoryStore.recordingsDir
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Open History") {
                        if let delegate = NSApp.delegate as? AppDelegate {
                            delegate.openHistory()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .onAppear { refreshStats() }
    }

    private func refreshStats() {
        let stats = HistoryStore.storageStats()
        recordingCount = stats.count
        storageSize = String(format: "%.1f MB on disk", Double(stats.bytes) / 1_000_000)
    }
}
