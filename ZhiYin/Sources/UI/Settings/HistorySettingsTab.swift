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
        let dir = HistoryStore.recordingsDir
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else {
            recordingCount = 0
            storageSize = "0 MB"
            return
        }
        let wavFiles = files.filter { $0.hasSuffix(".wav") }
        recordingCount = wavFiles.count
        var totalBytes: UInt64 = 0
        for file in wavFiles {
            if let attrs = try? fm.attributesOfItem(atPath: "\(dir)/\(file)"),
               let size = attrs[.size] as? UInt64 {
                totalBytes += size
            }
        }
        let mb = Double(totalBytes) / 1_000_000
        storageSize = String(format: "%.1f MB on disk", mb)
    }
}
