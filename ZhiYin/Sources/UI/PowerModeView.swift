import SwiftUI

struct PowerModeView: View {
    @ObservedObject private var manager = PowerModeManager.shared
    @State private var showAddSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection("Per-App Profiles") {
                Text("Automatically switch recognition mode based on the active app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            List {
                if manager.appModes.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "app.dashed")
                                .font(.title)
                                .foregroundStyle(.quaternary)
                            Text("No app profiles configured")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text("Add an app to customize its voice input behavior")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 20)
                        Spacer()
                    }
                } else {
                    ForEach(manager.appModes) { mode in
                        HStack(spacing: 12) {
                            Image(systemName: appIcon(for: mode.settings.postProcessing))
                                .font(.title3)
                                .foregroundColor(.accentColor)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.appName)
                                    .fontWeight(.medium)
                                Text(mode.bundleId)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text(mode.settings.postProcessing.displayName)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .foregroundStyle(.blue)
                                .background(.blue.opacity(0.1), in: Capsule())
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { manager.remove(at: $0) }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 160)

            HStack {
                Text("\(manager.appModes.count) profiles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add App", systemImage: "plus")
                        .font(.callout)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddAppModeSheet(manager: manager, isPresented: $showAddSheet)
        }
    }

    private func appIcon(for mode: PostProcessing) -> String {
        switch mode {
        case .formal: return "doc.text"
        case .casual: return "bubble.left"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .none: return "minus.circle"
        }
    }
}

struct AddAppModeSheet: View {
    @ObservedObject var manager: PowerModeManager
    @Binding var isPresented: Bool
    @State private var selectedApp: NSRunningApplication?
    @State private var selectedMode: PostProcessing = .formal

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Add App Profile")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                Text("Application")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $selectedApp) {
                    Text("Select an app...").tag(nil as NSRunningApplication?)
                    ForEach(runningApps, id: \.processIdentifier) { app in
                        Text(app.localizedName ?? app.bundleIdentifier ?? "Unknown")
                            .tag(app as NSRunningApplication?)
                    }
                }
                .labelsHidden()

                Text("Voice Mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $selectedMode) {
                    ForEach(PostProcessing.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    guard let app = selectedApp, let bid = app.bundleIdentifier else { return }
                    let mode = AppMode(
                        bundleId: bid,
                        appName: app.localizedName ?? bid,
                        modeName: selectedMode.displayName,
                        settings: ModeSettings(postProcessing: selectedMode)
                    )
                    manager.add(mode)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedApp == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
