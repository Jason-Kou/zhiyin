import SwiftUI
import SwiftData
import AudioToolbox

// Strong reference to keep delegate alive (NSApplication.delegate is weak)
private let appDelegate = AppDelegate()

@main
enum ZhiYinApp {
    static func main() {
        let app = NSApplication.shared
        app.delegate = appDelegate
        app.run()
    }
}

// MARK: - Recording State Machine

enum RecordingState: CustomStringConvertible {
    case idle
    case recording
    case stopping(reason: StopReason)
    case finalizing

    var description: String {
        switch self {
        case .idle: return "idle"
        case .recording: return "recording"
        case .stopping(let reason): return "stopping(\(reason))"
        case .finalizing: return "finalizing"
        }
    }
}

enum StopReason: CustomStringConvertible {
    case userRelease      // Normal hotkey release
    case timeLimit        // 5-minute max duration (SAFE-01, added in plan 02)
    case memoryPressure   // Mach API threshold (SAFE-02, added in plan 02)
    case userCancel       // ESC key

    var description: String {
        switch self {
        case .userRelease: return "userRelease"
        case .timeLimit: return "timeLimit"
        case .memoryPressure: return "memoryPressure"
        case .userCancel: return "userCancel"
        }
    }

    var overlayMessage: String {
        switch self {
        case .userRelease: return ""
        case .timeLimit: return "Recording stopped: time limit reached"
        case .memoryPressure: return "Recording stopped: low memory"
        case .userCancel: return ""
        }
    }

    var isForceStop: Bool {
        switch self {
        case .timeLimit, .memoryPressure: return true
        case .userRelease, .userCancel: return false
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem?
    var hotkeyManager: HotkeyManager?
    var audioRecorder: AudioRecorder?
    var transcriber: SenseVoiceTranscriber?
    var textInjector: TextInjector?
    var mediaController: MediaController?
    // var updaterController: SPUStandardUpdaterController?
    var enhanceHotkeyMonitor: Any?

    private var recordingState: RecordingState = .idle
    private var isServerReady = false
    private var recordingStartTime: Date?

    // MARK: - Safety Timers (SAFE-01, SAFE-02)
    private var safetyTimer: DispatchSourceTimer?
    private var memoryMonitor: DispatchSourceTimer?

    /// Maximum recording duration in seconds (per D-02: hardcoded 5 minutes, not configurable)
    private let maxRecordingDuration: TimeInterval = 300.0

    /// Memory footprint threshold for auto-stop (1.5 GB absolute -- conservative default with ~700 MB headroom above typical 800 MB baseline)
    private let memoryThresholdBytes: UInt64 = 1_500_000_000

    /// Backward-compatible computed property for code that checks recording status
    private var isRecording: Bool {
        if case .recording = recordingState { return true }
        return false
    }
    private var pythonProcess: Process?
    private var statusMenuItem: NSMenuItem?
    private var restartMenuItem: NSMenuItem?
    private var recordMenuItem: NSMenuItem?
    private var blinkTimer: Timer?
    private var blinkState = false
    private var statusMenu: NSMenu?
    private var hideDockIconItem: NSMenuItem?
    private var historyWindow: NSWindow?
    private var updateMenuItem: NSMenuItem?
    private var updateMenuSeparator: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("=== ZhiYin applicationDidFinishLaunching START ===")
        // Ensure language default is "auto" for new installs
        if UserDefaults.standard.string(forKey: "recognitionLanguage") == nil {
            UserDefaults.standard.set("auto", forKey: "recognitionLanguage")
        }
        // Migrate legacy "funasr-asr" engine to "funasr" (v0.8.0)
        if UserDefaults.standard.string(forKey: "sttEngine") == "funasr-asr" {
            UserDefaults.standard.set("funasr", forKey: "sttEngine")
        }
        // Final Touch is now always on; remove the orphan UserDefaults key
        // so it doesn't linger across upgrades.
        UserDefaults.standard.removeObject(forKey: "finalTouchEnabled")
        setupMenuBar()
        print("=== Menu bar done ===")

        audioRecorder = AudioRecorder()
        print("=== AudioRecorder done ===")
        transcriber = SenseVoiceTranscriber()
        print("=== Transcriber done ===")
        textInjector = TextInjector()
        mediaController = MediaController()

        // Request Accessibility permission early (needed for global hotkey).
        // Microphone permission is requested naturally on first recording attempt.
        if !TextInjector.hasAccessibilityPermission() {
            TextInjector.requestAccessibilityPermission()
        }

        // Start Python STT server
        startPythonServer()

        // Poll for server readiness
        waitForServer()

        // Setup global hotkey (default: Right Control, customizable in Settings)
        hotkeyManager = HotkeyManager(
            onStart: { [weak self] in self?.startRecording() },
            onStop: { [weak self] in self?.stopRecordingAndTranscribe() }
        )
        hotkeyManager?.onCancelRecording = { [weak self] in self?.cancelRecording() }

        // Refresh event tap a few times after launch.
        // macOS doesn't immediately propagate Accessibility permission to running apps,
        // so we recreate the tap to pick up the permission once it's effective.
        for delay in [5.0, 15.0, 30.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.hotkeyManager?.refreshEventTap()
            }
        }

        // Watch for hotkey changes from Settings
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, let manager = self.hotkeyManager else { return }
            let saved = UserDefaults.standard.string(forKey: "selectedHotkey") ?? HotkeyOption.rightControl.rawValue
            let newOption = HotkeyOption(rawValue: saved) ?? .rightControl
            if manager.selectedHotkey != newOption {
                manager.selectedHotkey = newOption
            }
        }

        // Cmd+E hotkey for manual AI enhancement of clipboard
        enhanceHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Cmd+E = keyCode 14
            if event.modifierFlags.contains(.command) && event.keyCode == 14 {
                self?.enhanceClipboard()
            }
        }

        // Bug #4: when a manual Settings check finds an update, refresh the status menu
        NotificationCenter.default.addObserver(
            forName: .zhiyinUpdateFound,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.addUpdateMenuItem()           // idempotent — safe to call repeatedly
            self?.showUpdateAlertIfNeeded()     // also show alert if not yet dismissed for this version
        }

        // Check for updates (non-blocking). check() self-retries internally.
        Task {
            await UpdateChecker.shared.check()
            await MainActor.run {
                if UpdateChecker.shared.hasUpdate {
                    self.addUpdateMenuItem()
                    self.showUpdateAlertIfNeeded()
                }
            }
        }

        // Clean up old history recordings (>30 days)
        HistoryStore.shared.cleanupOldRecords()

        print("ZhiYin started")

        // Auto-open settings on first launch for easy access
        if !UserDefaults.standard.bool(forKey: "hideDockIcon") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openSettings()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopBlinkTimer()
        stopPythonServer()
    }

    // MARK: - Menu Bar Icon (sized for status bar visibility)

    /// WeChat-style green for recording state
    private static let recordingColor = NSColor(red: 0.35, green: 0.78, blue: 0.48, alpha: 1.0)

    /// Creates a status-bar-sized SF Symbol so the icon is visible in the menu bar.
    private func statusBarImage(systemName: String, accessibilityDescription: String?) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        guard let img = NSImage(systemSymbolName: systemName, accessibilityDescription: accessibilityDescription),
              let sized = img.withSymbolConfiguration(config) else { return nil }
        sized.isTemplate = true
        return sized
    }

    /// Creates a tinted (non-template) SF Symbol for colored states like recording.
    private func tintedStatusBarImage(systemName: String, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        guard let img = NSImage(systemSymbolName: systemName, accessibilityDescription: "ZhiYin"),
              let sized = img.withSymbolConfiguration(config) else { return nil }

        let tinted = NSImage(size: sized.size, flipped: false) { rect in
            color.set()
            sized.draw(in: rect)
            NSGraphicsContext.current?.cgContext.setBlendMode(.sourceIn)
            rect.fill()
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    private func startBlinkTimer() {
        // Show solid red mic icon during recording (no blinking)
        if let button = statusItem?.button,
           let img = tintedStatusBarImage(systemName: "mic.fill", color: Self.recordingColor) {
            button.image = img
        }
    }

    private func stopBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkState = false
        // Restore normal white template icon
        if let button = statusItem?.button,
           let img = statusBarImage(systemName: "mic.fill", accessibilityDescription: "ZhiYin") {
            button.image = img
        }
    }

    // MARK: - Server Health Polling

    private func waitForServer() {
        updateStatus("Loading model...", icon: "hourglass")

        Task {
            var attempts = 0
            let maxAttempts = 120  // 2 minutes max wait
            while attempts < maxAttempts {
                if let transcriber = transcriber, await transcriber.isServerReady() {
                    await MainActor.run {
                        self.isServerReady = true
                        self.updateStatus("Ready", icon: "mic.fill")
                        self.restartMenuItem?.isHidden = true
                        print("STT server ready")
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                attempts += 1
            }
            await MainActor.run {
                self.updateStatus("Server timeout", icon: "exclamationmark.triangle")
                self.restartMenuItem?.isHidden = false
                print("STT server failed to become ready after \(maxAttempts)s")
            }
        }
    }

    private func updateStatus(_ text: String, icon: String) {
        statusMenuItem?.title = "ZhiYin — \(text)"
        if let button = statusItem?.button, let img = statusBarImage(systemName: icon, accessibilityDescription: "ZhiYin") {
            button.image = img
        }
    }

    /// Show a brief status then revert to Ready after delay
    private func flashStatus(_ text: String, icon: String, duration: TimeInterval = 2.0) {
        updateStatus(text, icon: icon)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.updateStatus("Ready", icon: "mic.fill")
        }
    }

    // MARK: - Python Server Management

    private static let zhiyinHome = NSString(string: "~/.zhiyin").expandingTildeInPath
    private static let venvPath = "\(zhiyinHome)/venv"
    // Use existing sensevoice venv as fallback for dev builds
    private static let fallbackVenvPython = NSString(string: "~/3_coding/sensevoice-coreml/.venv/bin/python").expandingTildeInPath
    private static let pipDeps = "fastapi uvicorn soundfile numpy mlx-audio==0.2.10 huggingface-hub mlx-whisper==0.4.3"

    /// Bundled Python runtime inside the .app bundle (for release builds)
    private static var bundledPython: String? {
        let path = Bundle.main.bundlePath + "/Contents/Resources/python-runtime/bin/python3"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Bundled site-packages inside the .app bundle
    private static var bundledPackages: String? {
        let path = Bundle.main.bundlePath + "/Contents/Resources/python-packages"
        return FileManager.default.isReadableFile(atPath: path) ? path : nil
    }

    /// Bundled FunASR model inside the .app bundle
    private static var bundledModel: String? {
        let path = Bundle.main.bundlePath + "/Contents/Resources/funasr-model"
        return FileManager.default.isReadableFile(atPath: path) ? path : nil
    }

    /// Whether this is a self-contained release build with bundled Python
    private static var isBundledBuild: Bool {
        bundledPython != nil && bundledPackages != nil
    }

    /// Resolve the Python interpreter to use
    private static var pythonPath: String {
        if let bundled = bundledPython { return bundled }
        let venvPy = "\(venvPath)/bin/python"
        if FileManager.default.fileExists(atPath: venvPy) { return venvPy }
        return fallbackVenvPython
    }

    private func startPythonServer() {
        guard let script = findServerScript() else {
            print("stt_server.py not found")
            updateStatus("Server script missing", icon: "exclamationmark.triangle")
            return
        }

        if Self.isBundledBuild {
            // Release build: bundled Python + packages, launch directly
            print("Using bundled Python runtime")
            launchServer(script: script)
        } else if !FileManager.default.fileExists(atPath: Self.pythonPath) {
            // Dev build: set up venv if needed
            updateStatus("Setting up Python env...", icon: "arrow.down.circle")
            setupVenv { [weak self] success in
                if success {
                    self?.launchServer(script: script)
                } else {
                    DispatchQueue.main.async {
                        self?.updateStatus("Setup failed", icon: "exclamationmark.triangle")
                    }
                }
            }
        } else {
            launchServer(script: script)
        }
    }

    private func setupVenv(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let home = Self.zhiyinHome

            // Create ~/.zhiyin/ if needed
            if !fm.fileExists(atPath: home) {
                try? fm.createDirectory(atPath: home, withIntermediateDirectories: true)
            }

            // Create venv
            let createVenv = Process()
            createVenv.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            createVenv.arguments = ["-m", "venv", Self.venvPath]
            do {
                try createVenv.run()
                createVenv.waitUntilExit()
                guard createVenv.terminationStatus == 0 else {
                    print("Failed to create venv")
                    completion(false)
                    return
                }
            } catch {
                print("Failed to create venv: \(error)")
                completion(false)
                return
            }

            // Install dependencies
            DispatchQueue.main.async { [weak self] in
                self?.updateStatus("Installing dependencies...", icon: "arrow.down.circle")
            }

            let pip = Process()
            pip.executableURL = URL(fileURLWithPath: Self.venvPath + "/bin/pip")
            pip.arguments = ["install"] + Self.pipDeps.split(separator: " ").map(String.init)
            let pipPipe = Pipe()
            pip.standardOutput = pipPipe
            pip.standardError = pipPipe

            pipPipe.fileHandleForReading.readabilityHandler = { handle in
                if let line = String(data: handle.availableData, encoding: .utf8), !line.isEmpty {
                    print("[pip] \(line)", terminator: "")
                }
            }

            do {
                try pip.run()
                pip.waitUntilExit()
                guard pip.terminationStatus == 0 else {
                    print("pip install failed")
                    completion(false)
                    return
                }
                print("Python dependencies installed successfully")
                completion(true)
            } catch {
                print("Failed to install dependencies: \(error)")
                completion(false)
            }
        }
    }

    private func launchServer(script: String) {
        DispatchQueue.main.async { [weak self] in
            self?.updateStatus("Starting server...", icon: "hourglass")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.pythonPath)
        process.arguments = [script]

        // Build environment: inherit system env, add bundled paths if available
        var env = ProcessInfo.processInfo.environment
        if let pkgs = Self.bundledPackages {
            // Prepend bundled packages to PYTHONPATH so they take priority
            let existing = env["PYTHONPATH"] ?? ""
            env["PYTHONPATH"] = existing.isEmpty ? pkgs : "\(pkgs):\(existing)"
        }
        if let model = Self.bundledModel {
            // Tell stt_server.py where to find the pre-bundled model
            env["ZHIYIN_MODEL_PATH"] = model
        }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // Empty data = EOF, stop monitoring to avoid busy-loop
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let line = String(data: data, encoding: .utf8), !line.isEmpty else { return }
            print("[STT Server] \(line)", terminator: "")
            self?.parseServerOutput(line)
        }

        do {
            try process.run()
            pythonProcess = process
            print("Python STT server started (PID: \(process.processIdentifier))")
        } catch {
            print("Failed to start Python server: \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.updateStatus("Server launch failed", icon: "exclamationmark.triangle")
            }
        }
    }

    private func parseServerOutput(_ output: String) {
        // Parse huggingface-hub download progress: "Downloading model.safetensors:  45%|..."
        // or custom progress lines from stt_server.py
        if output.contains("Downloading") {
            // Extract percentage if present
            if let range = output.range(of: #"(\d+)%"#, options: .regularExpression) {
                let pct = output[range].dropLast() // remove %
                DispatchQueue.main.async { [weak self] in
                    self?.updateStatus("Downloading model... \(pct)%", icon: "arrow.down.circle")
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.updateStatus("Downloading model...", icon: "arrow.down.circle")
                }
            }
        } else if output.contains("Loading model") || output.contains("loading model") {
            DispatchQueue.main.async { [weak self] in
                self?.updateStatus("Loading model...", icon: "hourglass")
            }
        } else if output.contains("model ready") || output.contains("Model ready") {
            DispatchQueue.main.async { [weak self] in
                self?.isServerReady = true
                self?.updateStatus("Ready", icon: "mic.fill")
            }
        }
    }

    private func findServerScript() -> String? {
        let candidates = [
            // Release build: bundled inside .app/Contents/Resources/
            Bundle.main.bundlePath + "/Contents/Resources/python/stt_server.py",
            // Dev build: relative to .app bundle
            Bundle.main.bundlePath + "/../python/stt_server.py",
            // Fallback: hardcoded dev path
            NSString(string: "~/3_coding/zhiyin/python/stt_server.py").expandingTildeInPath,
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func stopPythonServer() {
        guard let process = pythonProcess, process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
        pythonProcess = nil
        print("Python STT server stopped")
    }

    @objc private func restartServer() {
        stopPythonServer()
        isServerReady = false
        startPythonServer()
        waitForServer()
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button, let img = statusBarImage(systemName: "mic.fill", accessibilityDescription: "ZhiYin") {
            button.image = img
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        statusMenuItem = NSMenuItem(title: "ZhiYin — Starting...", action: nil, keyEquivalent: "")
        statusMenuItem?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        menu.addItem(statusMenuItem!)

        menu.addItem(NSMenuItem.separator())

        let restart = NSMenuItem(title: "Restart Server", action: #selector(restartServer), keyEquivalent: "r")
        restart.target = self
        restart.isHidden = true
        restartMenuItem = restart
        menu.addItem(restart)

        let record = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "")
        record.target = self
        record.isEnabled = true
        record.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        recordMenuItem = record
        menu.addItem(record)

        menu.addItem(NSMenuItem.separator())

        let historyItem = NSMenuItem(title: "History...", action: #selector(openHistory), keyEquivalent: "h")
        historyItem.target = self
        historyItem.isEnabled = true
        historyItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        menu.addItem(historyItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.isEnabled = true
        settingsItem.image = NSImage(systemSymbolName: "gear", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        let permissionsItem = NSMenuItem(title: "Accessibility Permissions...", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        permissionsItem.target = self
        permissionsItem.isEnabled = true
        permissionsItem.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
        menu.addItem(permissionsItem)

        let hideDock = NSMenuItem(title: "Hide Dock Icon", action: #selector(toggleHideDockIcon), keyEquivalent: "")
        hideDock.target = self
        hideDock.isEnabled = true
        hideDock.image = NSImage(systemSymbolName: "dock.arrow.down.rectangle", accessibilityDescription: nil)
        hideDock.state = UserDefaults.standard.bool(forKey: "hideDockIcon") ? .on : .off
        hideDockIconItem = hideDock
        menu.addItem(hideDock)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit ZhiYin", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = true
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)

        statusMenu = menu
        statusItem?.menu = menu
    }

    // MARK: - Recording

    @objc func toggleRecording() {
        if case .recording = recordingState {
            stopRecordingAndTranscribe()
            recordMenuItem?.title = "Start Recording"
            hotkeyManager?.notifyRecordingStopped()
        } else {
            startRecording()
            recordMenuItem?.title = "Stop Recording"
        }
    }

    private func startRecording() {
        guard case .idle = recordingState else {
            print("RecordingState: ignoring start request, current state: \(recordingState)")
            return
        }

        guard isServerReady else {
            print("Server not ready, ignoring recording request")
            updateStatus("Waiting for server...", icon: "hourglass")
            return
        }

        print("RecordingState: idle -> recording")
        recordingState = .recording
        recordingStartTime = Date()
        mediaController?.pauseIfPlaying()
        updateStatus("Recording...", icon: "mic.badge.plus")
        startBlinkTimer()
        RecordingOverlayController.shared.show()
        audioRecorder?.startRecording()
        startStreamingTranscription()
        startSafetyTimer()
        startMemoryMonitor()
        if let footprint = Self.currentMemoryFootprint() {
            print("Recording started. Memory footprint: \(footprint / 1_000_000)MB")
        } else {
            print("Recording started")
        }
    }

    private func cancelRecording() {
        requestStop(reason: .userCancel)
    }

    private func stopRecordingAndTranscribe() {
        requestStop(reason: .userRelease)
    }

    /// Single entry point for all stop triggers. Only the first caller
    /// that sees .recording transitions to .stopping; subsequent callers no-op.
    private func requestStop(reason: StopReason) {
        guard case .recording = recordingState else {
            print("RecordingState: ignoring stop request (\(reason)), current state: \(recordingState)")
            return
        }
        print("RecordingState: \(recordingState) -> stopping(\(reason))")
        recordingState = .stopping(reason: reason)
        performStop(reason: reason)
    }

    /// Executes the actual stop sequence after state has transitioned to .stopping.
    private func performStop(reason: StopReason) {
        // Cancel safety timers immediately for ALL stop reasons
        cancelSafetyTimer()
        cancelMemoryMonitor()

        // Play appropriate sound for forced stops (per D-05)
        if reason.isForceStop {
            AudioServicesPlaySystemSound(1115)
        }

        stopBlinkTimer()
        stopStreamingTranscription()
        mediaController?.resumeIfWasPlaying()

        // Handle cancel case
        if case .userCancel = reason {
            _ = audioRecorder?.stopRecording()
            audioRecorder?.cleanup()
            Task { await transcriber?.cancelSession() }
            updateStatus("Ready", icon: "mic.fill")
            RecordingOverlayController.shared.dismiss()
            recordingState = .idle
            print("RecordingState: stopping(userCancel) -> idle")
            print("Recording cancelled")
            return
        }

        // Check if recording was too short (only for user release)
        if case .userRelease = reason, audioRecorder?.wasRecordingTooShort == true {
            _ = audioRecorder?.stopRecording()
            audioRecorder?.cleanup()
            Task { await transcriber?.cancelSession() }
            updateStatus("Ready", icon: "mic.fill")
            RecordingOverlayController.shared.dismiss()
            recordingState = .idle
            print("RecordingState: stopping(userRelease) -> idle (too short)")
            print("Recording too short, ignored")
            return
        }

        // Transition to finalizing
        print("RecordingState: stopping(\(reason)) -> finalizing")
        recordingState = .finalizing

        updateStatus("Transcribing...", icon: "ellipsis.circle")

        // Per D-06: show force-stop message in overlay, or show transcribing
        if reason.isForceStop {
            RecordingOverlayController.shared.showForceStopped(message: reason.overlayMessage)
        } else {
            RecordingOverlayController.shared.showTranscribing()
        }

        // Stop audio engine first, then drain — stopping ensures the callback
        // won't add more samples, so drain gets everything including the very end.
        let audioURL = audioRecorder?.stopRecording()
        let remainingSamples = audioRecorder?.drainNewSamples()

        print("Recording stopped (\(reason)), finalizing transcription...")

        Task {
            // Send remaining samples to server before finalizing
            if let remainingSamples = remainingSamples {
                try? await transcriber?.sendChunk(samples: remainingSamples)
            }

            // Wait for the last in-flight chunk upload to complete.
            // Without this, the last timer-fired sendChunk may still be in
            // flight when finalizeSession pops the session, losing audio.
            await lastChunkTask?.value
            lastChunkTask = nil

            var text: String?
            // Final Touch is now always on. The streaming-only "else" branch
            // below is preserved as dead code — flip this back to a UserDefaults
            // read if/when streaming quality matures enough to justify the
            // latency tradeoff.
            let finalTouch = true

            if finalTouch {
                // Final Touch ON: upload whole audio for best accuracy
                // (streaming was only for real-time preview)
                await transcriber?.cancelSession()
                if let audioURL = audioURL {
                    do {
                        text = try await transcriber?.transcribe(audioURL: audioURL)
                        print("Final Touch result: \(text ?? "")")
                    } catch {
                        print("Final Touch failed: \(error)")
                    }
                }
            } else {
                // Normal: streaming segments + tail (fast)
                if transcriber?.activeSessionId != nil {
                    text = try? await transcriber?.finalizeSession(mode: "quick")
                    print("Streaming result: \(text ?? "")")
                }
                // Fallback: file upload if empty
                if text == nil || text?.isEmpty == true, let audioURL = audioURL {
                    text = try? await transcriber?.transcribe(audioURL: audioURL)
                }
            }

            // Calculate recording duration
            let duration = self.recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

            if let text = text, !text.isEmpty {
                var processed = await self.processText(text)

                // Save to history (before upgrade notices corrupt the text)
                await MainActor.run {
                    HistoryStore.shared.save(text: text, duration: duration, tempAudioURL: audioURL)
                }

                // Track usage and wrap text with upgrade notice if over limit
                let isPro = UserDefaults.standard.bool(forKey: "isPro")
                if !isPro {
                    let withinLimit = UsageTracker.shared.record()
                    if !withinLimit {
                        processed = Self.insertUpgradeNotices(processed)
                    }
                }

                await MainActor.run {
                    RecordingOverlayController.shared.dismiss()
                    let injected = textInjector?.injectText(processed) ?? false
                    if injected {
                        flashStatus("\u{2713} Done", icon: "checkmark.circle")
                    } else {
                        flashStatus("\u{2717} No Permission", icon: "exclamationmark.triangle")
                    }
                    self.recordingState = .idle
                    print("RecordingState: finalizing -> idle")
                }
            } else {
                await MainActor.run {
                    flashStatus("\u{2717} Failed", icon: "xmark.circle")
                    RecordingOverlayController.shared.dismiss()
                    self.recordingState = .idle
                    print("RecordingState: finalizing -> idle")
                }
            }

            audioRecorder?.cleanup()
        }
    }

    // MARK: - Safety Timer & Memory Monitor (SAFE-01, SAFE-02)

    /// Start a one-shot timer that auto-stops recording after maxRecordingDuration.
    /// Uses DispatchSource (not NSTimer) because GCD timers are RunLoop-mode-independent.
    private func startSafetyTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + maxRecordingDuration)
        timer.setEventHandler { [weak self] in
            print("SafetyTimer: max recording duration reached (\(self?.maxRecordingDuration ?? 0)s)")
            self?.requestStop(reason: .timeLimit)
        }
        timer.resume()
        safetyTimer = timer
    }

    private func cancelSafetyTimer() {
        safetyTimer?.cancel()
        safetyTimer = nil
    }

    /// Start periodic memory monitoring. Fires every 5 seconds on a utility queue.
    /// If phys_footprint exceeds threshold, dispatches stop to main thread.
    private func startMemoryMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5.0, repeating: 5.0, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard let footprint = Self.currentMemoryFootprint() else { return }
            if footprint > self.memoryThresholdBytes {
                let footprintMB = footprint / 1_000_000
                let thresholdMB = self.memoryThresholdBytes / 1_000_000
                print("MemoryMonitor: footprint \(footprintMB)MB exceeds threshold \(thresholdMB)MB")
                DispatchQueue.main.async {
                    self.requestStop(reason: .memoryPressure)
                }
            }
        }
        timer.resume()
        memoryMonitor = timer
    }

    private func cancelMemoryMonitor() {
        memoryMonitor?.cancel()
        memoryMonitor = nil
    }

    /// Read current process physical memory footprint via Mach API.
    /// Returns bytes. Matches Activity Monitor "Memory" column.
    static func currentMemoryFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { machPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), machPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    // MARK: - Streaming with VAD (sentence-boundary triggered transcription)

    private var chunkTimer: Timer?
    private var lastChunkTask: Task<Void, Never>?

    private func startStreamingTranscription() {
        // Start a session on the server (VAD + chunked upload)
        Task {
            do {
                let sessionId = try await transcriber?.startSession()
                print("VAD session started: \(sessionId ?? "nil")")
            } catch {
                print("Failed to start session: \(error)")
                return
            }

            // Send audio chunks every 0.3s — server runs VAD and returns transcribed text
            await MainActor.run {
                self.chunkTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    self?.sendAudioChunk()
                }
            }
        }
    }

    private func stopStreamingTranscription() {
        chunkTimer?.invalidate()
        chunkTimer = nil
    }

    /// Send new audio chunk to server. Server runs VAD, auto-transcribes completed sentences,
    /// and returns accumulated text in the response.
    private func sendAudioChunk() {
        guard case .recording = recordingState else { return }
        guard let samples = audioRecorder?.drainNewSamples() else { return }

        lastChunkTask = Task {
            do {
                let result = try await transcriber?.sendChunk(samples: samples)
                if let text = result?.text, !text.isEmpty {
                    await MainActor.run {
                        RecordingOverlayController.shared.updateText(text)
                    }
                }
            } catch {
                // Silently ignore chunk errors
            }
        }
    }

    /// Insert upgrade notices between every word/character for maximum obfuscation.
    static func insertUpgradeNotices(_ text: String) -> String {
        let tag = "[Upgrade to Pro]"
        let endTag = " [Upgrade to Pro — zhiyin.app]"

        // Split by whitespace to get words; for Chinese text, split into individual characters
        let segments = text.flatMap { char -> [String] in
            if char.isWhitespace {
                return [String(char)]
            } else if char.unicodeScalars.allSatisfy({ $0.value > 0x2E80 }) {
                // CJK character — treat each as a separate segment
                return [String(char)]
            } else {
                return [String(char)]
            }
        }

        // Group consecutive non-CJK, non-whitespace chars back into words
        var words: [String] = []
        var current = ""
        for seg in segments {
            let ch = seg.first!
            if ch.isWhitespace {
                if !current.isEmpty { words.append(current); current = "" }
                words.append(seg)
            } else if ch.unicodeScalars.allSatisfy({ $0.value > 0x2E80 }) {
                if !current.isEmpty { words.append(current); current = "" }
                words.append(seg)
            } else {
                current += seg
            }
        }
        if !current.isEmpty { words.append(current) }

        guard words.count > 1 else {
            return tag + " " + text + endTag
        }

        // Join with tag between every word/character
        let result = words.joined(separator: " \(tag) ")
        return tag + " " + result + endTag
    }

    /// Apply smart replacements, personal dictionary, then optionally AI enhancement
    private func processText(_ text: String) async -> String {
        // 1. Smart text replacements first (e.g. "换行" → "\n")
        var result = TextReplacementManager.shared.applyReplacements(text)

        // 2. Personal dictionary replacements
        result = PersonalDictionary.shared.applyReplacements(result)

        // 3. AI enhancement if enabled
        let enhancer = TextEnhancer.shared
        if enhancer.isEnabled {
            // Check Power Mode for current app override
            if let appMode = PowerModeManager.shared.modeForCurrentApp() {
                let mode: EnhanceMode = {
                    switch appMode.settings.postProcessing {
                    case .formal: return .formal
                    case .casual: return .casual
                    case .code: return .grammar
                    case .none: return enhancer.enhanceMode
                    }
                }()
                result = await enhancer.enhance(text: result, mode: mode)
            } else {
                result = await enhancer.enhance(text: result)
            }
        }

        return result
    }

    /// Cmd+E: enhance current clipboard text with AI
    private func enhanceClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        Task {
            let enhanced = await TextEnhancer.shared.enhance(text: text)
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(enhanced, forType: .string)
                flashStatus("Enhanced", icon: "sparkles")
            }
        }
    }

    private var settingsWindow: NSWindow?
    
    @objc func openSettings() {
        setupMainMenuIfNeeded()
        // Always show Dock icon while Settings is open (required by macOS)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "ZhiYin Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 680, height: 500))
        window.minSize = NSSize(width: 600, height: 400)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
    }

    /// Set up the application main menu with an Edit menu so that
    /// standard keyboard shortcuts (⌘C, ⌘V, ⌘X, ⌘A) work in text fields.
    private func setupMainMenuIfNeeded() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About ZhiYin", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit ZhiYin", action: #selector(quitApp), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu — enables ⌘C/⌘V/⌘X/⌘A in text fields
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func windowWillClose(_ notification: Notification) {
        // Clear reference when history window closes
        if let window = notification.object as? NSWindow, window === historyWindow {
            historyWindow = nil
        }
        // Hide Dock icon when no windows are visible (VoiceInk pattern)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let hasVisibleWindows = NSApp.windows.contains {
                $0.isVisible && $0.level == .normal
            }
            if !hasVisibleWindows {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    @objc func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func toggleHideDockIcon() {
        let current = UserDefaults.standard.bool(forKey: "hideDockIcon")
        let newValue = !current
        UserDefaults.standard.set(newValue, forKey: "hideDockIcon")
        hideDockIconItem?.state = newValue ? .on : .off

        if newValue {
            // Hide Dock: close settings window, then switch to accessory
            settingsWindow?.close()
            NSApp.setActivationPolicy(.accessory)
        } else if settingsWindow?.isVisible == true {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - History Window

    @objc func openHistory() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window = historyWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let historyView = TranscriptionHistoryView()
            .modelContainer(HistoryStore.shared.container)

        let hostingController = NSHostingController(rootView: historyView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "ZhiYin — Transcription History"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 900, height: 600))
        window.minSize = NSSize(width: 700, height: 400)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        historyWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func addUpdateMenuItem() {
        guard let menu = statusMenu else { return }
        if updateMenuItem != nil { return }  // Bug #4: already added, don't double-insert
        let version = UpdateChecker.shared.latestVersion ?? "new"
        let item = NSMenuItem(title: "Update Available: v\(version)", action: #selector(openUpdatePage), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        let separator = NSMenuItem.separator()
        // Insert before the Quit separator
        let insertIndex = max(0, menu.numberOfItems - 2)
        menu.insertItem(item, at: insertIndex)
        menu.insertItem(separator, at: insertIndex)
        updateMenuItem = item
        updateMenuSeparator = separator
    }

    func showUpdateAlertIfNeeded() {
        guard let latest = UpdateChecker.shared.latestVersion else { return }
        let dismissedKey = "updateAlertDismissedVersion"
        let dismissed = UserDefaults.standard.string(forKey: dismissedKey)
        if dismissed == latest { return }  // already dismissed this version — don't nag

        let alert = NSAlert()
        alert.messageText = "ZhiYin Update Available"
        alert.informativeText = "A new version is available.\n\nCurrent: v\(UpdateChecker.currentVersion)\nLatest: v\(latest)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")

        // Bring the alert to the foreground (LSUIElement=true menu-bar apps have no focus by default)
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        UserDefaults.standard.set(latest, forKey: dismissedKey)  // mark dismissed regardless of choice
        if response == .alertFirstButtonReturn {
            // Download
            if let urlStr = UpdateChecker.shared.downloadURL, let url = URL(string: urlStr) {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.open(UpdateChecker.shared.releasesPageURL)
            }
        }
        // "Later" — do nothing extra; dismissed key already set above
    }

    @objc func openUpdatePage() {
        if let urlStr = UpdateChecker.shared.downloadURL,
           let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(UpdateChecker.shared.releasesPageURL)
        }
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
