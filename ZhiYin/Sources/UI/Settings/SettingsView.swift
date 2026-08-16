import SwiftUI

// MARK: - Settings Navigation

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case aiAgent = "AI Agent"
    case history = "History"
    case dictionary = "Dictionary"
    case permissions = "Permissions"
    case license = "License"
    case about = "About"

    var id: String { rawValue }

    /// Tabs actually shown in the sidebar. The License tab is hidden while
    /// UsageTracker.monetizationEnabled is false — there is nothing to buy.
    static var visibleCases: [SettingsTab] {
        allCases.filter { $0 != .license || UsageTracker.monetizationEnabled }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .aiAgent: return "sparkles"
        case .history: return "clock.arrow.circlepath"
        case .dictionary: return "book.fill"
        case .permissions: return "lock.shield"
        case .license: return "key.fill"
        case .about: return "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Hotkey, language, device"
        case .aiAgent: return "AI contextual reply"
        case .history: return "Transcription history"
        case .dictionary: return "Custom words & terms"
        case .permissions: return "System permissions"
        case .license: return "Pro activation"
        case .about: return "Version & links"
        }
    }
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                detailContent
                    .frame(maxWidth: 480)
                    .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 680, height: 500)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ForEach(SettingsTab.visibleCases) { tab in
                sidebarButton(for: tab)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .frame(width: 210)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func sidebarButton(for tab: SettingsTab) -> some View {
        Button(action: {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { selectedTab = tab }
        }) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .foregroundColor(.accentColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.rawValue)
                        .font(.body)
                    Text(tab.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selectedTab == tab ? Color.accentColor.opacity(0.2) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedTab {
        case .general: GeneralTab()
        case .aiAgent: AIAgentTab()
        case .history: HistorySettingsTab()
        case .dictionary: DictionaryView()
        case .permissions: PermissionsTab()
        case .license: LicenseTab()
        case .about: AboutTab()
        }
    }
}
