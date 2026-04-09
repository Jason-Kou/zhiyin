import SwiftUI

import LaunchAtLogin
import AVFoundation

// MARK: - Settings Navigation

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case history = "History"
    case dictionary = "Dictionary"
    case permissions = "Permissions"
    case license = "License"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gear"
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
            ForEach(SettingsTab.allCases) { tab in
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
        Button(action: { selectedTab = tab }) {
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
        case .history: HistorySettingsTab()
        case .dictionary: DictionaryView()
        case .permissions: PermissionsTab()
        case .license: LicenseTab()
        case .about: AboutTab()
        }
    }
}

// MARK: - Section Header

struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Setting Row

struct SettingRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(label)
                .frame(minWidth: 100, alignment: .leading)
            Spacer()
            content
        }
    }
}

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

// MARK: - Audio Device Discovery

struct AudioInputDevice: Identifiable, Hashable {
    let id: String  // UID
    let name: String
}

func getAudioInputDevices() -> [AudioInputDevice] {
    var devices: [AudioInputDevice] = [
        AudioInputDevice(id: "default", name: "System Default")
    ]

    let discoverySession = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone, .external],
        mediaType: .audio,
        position: .unspecified
    )

    for device in discoverySession.devices {
        devices.append(AudioInputDevice(id: device.uniqueID, name: device.localizedName))
    }

    return devices
}

// MARK: - General Tab

struct GeneralTab: View {
    @AppStorage("inputDeviceUID") private var inputDeviceUID = "default"
    @AppStorage("selectedHotkey") private var selectedHotkeyRaw = HotkeyOption.leftControlOption.rawValue
    @AppStorage("outputTraditionalChinese") private var outputTraditionalChinese = false
    @AppStorage("recognitionLanguage") private var recognitionLanguage = "auto"
    @AppStorage("sttEngine") private var sttEngine = "funasr"
    @State private var audioDevices: [AudioInputDevice] = []
    @StateObject private var modelManager = ModelManager.shared
    @State private var showDownloadAlert = false
    @State private var pendingEngine = ""
    private var selectedHotkey: Binding<HotkeyOption> {
        Binding(
            get: { HotkeyOption(rawValue: selectedHotkeyRaw) ?? .leftControlOption },
            set: { selectedHotkeyRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("Hotkey") {
                SettingRow("Record Hotkey") {
                    Picker("", selection: selectedHotkey) {
                        ForEach(HotkeyOption.allCases) { option in
                            Text("\(option.symbol) \(option.displayName)").tag(option)
                        }
                    }
                    .frame(width: 200)
                }
                Text("Press to start, press again to stop. Double-press ESC to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection("Recognition") {
                SettingRow("STT Engine") {
                    HStack(spacing: 6) {
                        Picker("", selection: $sttEngine) {
                            Text("FunASR").tag("funasr")
                            Text("Whisper Q4").tag("whisper")
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        .onChange(of: sttEngine) { oldValue, newValue in
                            if let model = modelManager.models.first(where: { $0.engine == newValue }),
                               !model.cached {
                                sttEngine = oldValue
                                pendingEngine = newValue
                                showDownloadAlert = true
                                return
                            }
                            LanguageSettings.shared.notifyServer()
                        }

                        Button(action: {
                            let modelDir: String
                            switch sttEngine {
                            case "whisper":
                                modelDir = "models--mlx-community--whisper-large-v3-turbo-q4"
                            default:
                                modelDir = "models--mlx-community--Fun-ASR-MLT-Nano-2512-8bit"
                            }
                            let path = NSString(string: "~/.cache/huggingface/hub/\(modelDir)").expandingTildeInPath
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                        }) {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("Open model folder in Finder")
                    }
                }

                // Model status rows
                if !modelManager.models.isEmpty {
                    ForEach(modelManager.models) { model in
                        ModelStatusRow(
                            model: model,
                            isActive: model.engine == sttEngine,
                            onDownload: {
                                Task { await modelManager.downloadModel(model.engine) }
                            },
                            onDelete: {
                                Task { await modelManager.deleteModel(model.engine) }
                            }
                        )
                    }
                }

                Text("FunASR: fast, auto-punctuation. MLT: 31 languages but may translate. Whisper Q4: most reliable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                SettingRow("Language") {
                    Picker("", selection: $recognitionLanguage) {
                        ForEach(LanguageSettings.languages(for: sttEngine)) { lang in
                            Text("\(lang.flag) \(lang.label)").tag(lang.code)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .onChange(of: recognitionLanguage) {
                        LanguageSettings.shared.notifyServer()
                    }
                    .onChange(of: sttEngine) {
                        // Reset to auto if current language isn't supported by new engine
                        let supported = LanguageSettings.languages(for: sttEngine).map(\.code)
                        if !supported.contains(recognitionLanguage) {
                            recognitionLanguage = "auto"
                        }
                    }
                }
                Text("Select your primary language for better accuracy. Other languages are still recognized. Use Auto-detect if unsure.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                SettingRow("Traditional Chinese") {
                    Toggle("", isOn: $outputTraditionalChinese)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .onChange(of: outputTraditionalChinese) {
                            LanguageSettings.shared.notifyServer()
                        }
                }
                Text("Output traditional characters for Chinese transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection("Microphone") {
                SettingRow("Input Device") {
                    Picker("", selection: $inputDeviceUID) {
                        ForEach(audioDevices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .onAppear { audioDevices = getAudioInputDevices() }
                }

                HStack {
                    Spacer()
                    Button {
                        audioDevices = getAudioInputDevices()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }

            SettingsSection("Startup") {
                LaunchAtLogin.Toggle("Launch at login")
            }
        }
        .onAppear {
            Task { await modelManager.fetchModels() }
            modelManager.onDownloadComplete = { [self] engine in
                if engine == pendingEngine {
                    sttEngine = engine
                    pendingEngine = ""
                    LanguageSettings.shared.notifyServer()
                }
            }
        }
        .alert("Model Not Downloaded", isPresented: $showDownloadAlert) {
            Button("Download") {
                Task {
                    await modelManager.downloadModel(pendingEngine)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let size = modelManager.models.first(where: { $0.engine == pendingEngine })?.sizeMB ?? 0
            Text("The model needs to be downloaded first (~\(size) MB). Download now?")
        }
    }
}

// MARK: - Model Status Row

struct ModelStatusRow: View {
    let model: ModelManager.ModelInfo
    let isActive: Bool
    let onDownload: () -> Void
    let onDelete: () -> Void
    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.system(size: 12, weight: .medium))
                Text("\(model.sizeMB) MB")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 160, alignment: .leading)

            Spacer()

            if model.downloading {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: Double(model.progress), total: 100)
                        .frame(width: 80)
                    Text("\(model.progress)%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else if model.cached {
                if isActive {
                    Text("Active")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                } else {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                Button {
                    onDownload()
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
        .alert("Delete Model?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete \(model.displayName) (\(model.sizeMB) MB)? You can re-download it later.")
        }
    }
}

// MARK: - Permissions Tab

struct PermissionsTab: View {
    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("App Permissions")
                    .font(.title2.bold())
                Text("ZhiYin requires the following permissions to function properly")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)

            SettingsSection("Required Permissions") {
                PermissionRow(
                    icon: "mic.fill",
                    iconColor: .green,
                    title: "Microphone Access",
                    description: "Allow ZhiYin to record your voice for transcription",
                    isGranted: micGranted,
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                    onRefresh: { refreshPermissions() }
                )

                Divider()

                PermissionRow(
                    icon: "hand.raised.fill",
                    iconColor: .orange,
                    title: "Accessibility Access",
                    description: "Allow ZhiYin to use global hotkeys and paste text at cursor",
                    isGranted: accessibilityGranted,
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                    onRefresh: { refreshPermissions() }
                )
            }

            if !micGranted || !accessibilityGranted {
                SettingsSection("Tips") {
                    Label("Accessibility may require restarting ZhiYin after granting", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            refreshPermissions()
            startPolling()
        }
        .onDisappear {
            stopPolling()
        }
    }

    private func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = TextInjector.hasAccessibilityPermission()
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            refreshPermissions()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

struct PermissionRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    let isGranted: Bool
    let settingsURL: String
    let onRefresh: () -> Void

    private var activeColor: Color { isGranted ? .green : iconColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(activeColor.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 16))
                        .foregroundStyle(activeColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Refresh status")

                if isGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.red)
                }
            }

            if !isGranted {
                Button(action: {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack {
                        Text("Open System Settings")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - License Tab

struct LicenseTab: View {
    @AppStorage("licenseKey") private var licenseKey = ""
    @AppStorage("isPro") private var isPro = false
    @StateObject private var usage = UsageTracker.shared
    @StateObject private var updater = UpdateChecker.shared
    @StateObject private var licenseManager = LicenseManager.shared
    @State private var keyInput = ""
    @State private var isChecking = false
    @State private var checkResult: String? = nil

    private static let zhiyinGreen = Color(red: 0.35, green: 0.78, blue: 0.48)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if isPro {
                // Pro user view
                SettingsSection("License") {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title2)
                            .foregroundStyle(Self.zhiyinGreen)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("ZhiYin")
                                    .font(.headline)
                                Text("PRO")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .foregroundStyle(.white)
                                    .background(Self.zhiyinGreen, in: RoundedRectangle(cornerRadius: 4))
                            }
                            Text("Lifetime · Unlimited transcriptions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Manage License") {
                            NSWorkspace.shared.open(LicenseManager.customerPortalURL)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button("Deactivate") {
                            Task { await licenseManager.deactivate() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

            } else {
                // Free user view
                SettingsSection("Free Tier Usage") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Today: \(usage.todayCount) / \(UsageTracker.dailyFreeLimit)")
                                .font(.callout)
                            Text("\(usage.remaining) transcriptions remaining")
                                .font(.caption)
                                .foregroundStyle(usage.isOverLimit ? .red : .secondary)
                        }
                        Spacer()
                        ProgressView(value: min(Double(usage.todayCount), Double(UsageTracker.dailyFreeLimit)),
                                     total: Double(UsageTracker.dailyFreeLimit))
                            .frame(width: 100)
                            .tint(usage.isOverLimit ? .red : .accentColor)
                    }
                }

                SettingsSection("Activate License") {
                    activationView
                }

                SettingsSection("Get Pro") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Unlimited transcriptions, no daily limits")
                                .font(.callout)
                            Text("One-time purchase · Lifetime")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Buy Pro — $12") {
                            NSWorkspace.shared.open(LicenseManager.checkoutURL)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                SettingsSection("Already purchased?") {
                    HStack {
                        Text("Manage your license and device activations")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("License Management Portal") {
                            NSWorkspace.shared.open(LicenseManager.customerPortalURL)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            // Updates section visible to ALL users (Bug #2)
            updatesSection
        }
    }

    private var updatesSection: some View {
        SettingsSection("Updates") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current version: \(UpdateChecker.currentVersion)")
                        .font(.callout)
                    if let result = checkResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(updater.hasUpdate ? Self.zhiyinGreen : .secondary)
                    } else if updater.hasUpdate, let version = updater.latestVersion {
                        Text("v\(version) available")
                            .font(.caption)
                            .foregroundStyle(Self.zhiyinGreen)
                    } else {
                        Text("You're up to date")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(isChecking ? "Checking..." : "Check for Updates") {
                    Task {
                        isChecking = true
                        checkResult = nil
                        await UpdateChecker.shared.check()
                        isChecking = false
                        if updater.hasUpdate, let v = updater.latestVersion {
                            checkResult = "Update available: v\(v)"
                        } else {
                            checkResult = "You're up to date (v\(UpdateChecker.currentVersion))"
                        }
                        // Auto-clear inline result after 5 seconds so the section returns to its default state
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        checkResult = nil
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isChecking)
            }
        }
    }

    private var activationView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Enter License Key", text: $keyInput)
                    .textFieldStyle(.roundedBorder)
                Button(licenseManager.isActivating ? "Verifying..." : "Activate") {
                    Task {
                        let success = await licenseManager.activate(key: keyInput)
                        if success { keyInput = "" }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(keyInput.isEmpty || licenseManager.isActivating)
            }

            if !licenseManager.errorMessage.isEmpty {
                Text(licenseManager.errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }
}

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
                Text("Old recordings and transcriptions are automatically removed on launch.")
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
                    Button("Open History") {
                        if let delegate = NSApp.delegate as? AppDelegate {
                            delegate.openHistory()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                HStack {
                    Spacer()
                    Button("Show in Finder") {
                        let path = HistoryStore.recordingsDir
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                    }
                    .buttonStyle(.bordered)
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