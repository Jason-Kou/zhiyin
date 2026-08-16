import SwiftUI

// MARK: - About Tab

struct AboutTab: View {
    @StateObject private var updater = UpdateChecker.shared

    private var appIcon: NSImage? {
        if let url = Bundle.main.url(forResource: "icon-1024", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSApp.applicationIconImage
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 128, height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            }

            VStack(spacing: 4) {
                Text("ZhiYin")
                    .font(.system(size: 28, weight: .bold))
                Text("The fastest voice input for macOS")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Version \(UpdateChecker.currentVersion)")
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())

            if updater.hasUpdate, let version = updater.latestVersion {
                Link(destination: URL(string: updater.downloadURL ?? updater.releasesPageURL.absoluteString)!) {
                    Label("v\(version) Available — Download", systemImage: "arrow.down.circle.fill")
                }
                .font(.callout.bold())
                .foregroundStyle(.blue)
            }

            HStack(spacing: 20) {
                Link(destination: URL(string: "https://github.com/Jason-Kou/zhiyin")!) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://x.com/AgentLabX")!) {
                    Label("AgentLabX", systemImage: "xmark")
                }
            }
            .font(.callout)

            // CLI install section — hidden for now, will be a standalone feature
            // Divider().padding(.horizontal, 40)
            // CLIInstallSection()

            Spacer()

            Text("\u{00A9} 2026 AgentLabX. MIT License.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - CLI Install Section

struct CLIInstallSection: View {
    @State private var cliInstalled = false
    @State private var installError = ""

    var body: some View {
        VStack(spacing: 8) {
            if cliInstalled {
                Label("CLI Installed", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                Text("Use: zhiyin-stt <audio_file>")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    installCLI()
                } label: {
                    Label("Install CLI Tool", systemImage: "terminal")
                        .font(.callout)
                }

                Text("Adds zhiyin-stt command for agent/tool integration")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !installError.isEmpty {
                    Text(installError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .onAppear {
            cliInstalled = FileManager.default.fileExists(atPath: "/usr/local/bin/zhiyin-stt")
        }
    }

    private func installCLI() {
        // Find CLI binary in app bundle
        let bundleCLI = Bundle.main.bundlePath + "/Contents/Resources/bin/zhiyin-stt"
        guard FileManager.default.fileExists(atPath: bundleCLI) else {
            installError = "CLI binary not found in app bundle"
            return
        }

        let script = "do shell script \"mkdir -p /usr/local/bin && ln -sf '\(bundleCLI)' /usr/local/bin/zhiyin-stt\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)

        if error != nil {
            installError = "Installation cancelled or failed"
        } else {
            cliInstalled = true
            installError = ""
        }
    }
}
