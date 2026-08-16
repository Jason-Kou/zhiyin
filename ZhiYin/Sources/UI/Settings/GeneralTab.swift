import SwiftUI
import AVFoundation
import LaunchAtLogin

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
    @AppStorage("selectedAIHotkey") private var selectedAIHotkeyRaw = HotkeyOption.fnOption.rawValue
    @AppStorage("outputTraditionalChinese") private var outputTraditionalChinese = false
    @AppStorage("convertChineseNumerals") private var convertChineseNumerals = false
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

    private var aiHotkey: HotkeyOption {
        HotkeyOption(rawValue: selectedAIHotkeyRaw) ?? .fnOption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("Hotkey") {
                SettingRow("Record Hotkey") {
                    HotkeyPicker(selection: selectedHotkey, reservedBy: aiHotkey)
                        .frame(width: 220)
                }
                Text("Press to start, press again to stop. Double-press ESC to cancel. The AI Agent Hotkey (\(aiHotkey.displayName)) is greyed out to prevent conflicts.")
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

                Divider()

                SettingRow("Arabic numerals") {
                    Toggle("", isOn: $convertChineseNumerals)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .onChange(of: convertChineseNumerals) {
                            LanguageSettings.shared.notifyServer()
                        }
                }
                Text("Write spoken decimals as digits — \"三点五\" becomes \"3.5\". Numerals inside ordinary words are left alone.")
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
