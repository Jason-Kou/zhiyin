import AppKit
import ApplicationServices
import Carbon

// MARK: - Hotkey Options

enum HotkeyOption: String, CaseIterable, Identifiable {
    case leftControlOption = "leftControlOption"
    case rightControlOption = "rightControlOption"
    case leftControlCommand = "leftControlCommand"
    case rightControl = "rightControl"
    case leftControl = "leftControl"
    case rightOption = "rightOption"
    case leftOption = "leftOption"
    case fnControl = "fnControl"
    case fn = "fn"
    case none = "none"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftControlOption: return "Left Control + Option"
        case .rightControlOption: return "Right Control + Option"
        case .leftControlCommand: return "Left Control + Command"
        case .rightControl: return "Right Control"
        case .leftControl: return "Left Control"
        case .rightOption: return "Right Option"
        case .leftOption: return "Left Option"
        case .fnControl: return "Fn + Control"
        case .fn: return "Fn"
        case .none: return "None (Disabled)"
        }
    }

    var symbol: String {
        switch self {
        case .leftControlOption, .rightControlOption: return "⌃⌥"
        case .leftControlCommand: return "⌃⌘"
        case .rightControl, .leftControl: return "⌃"
        case .rightOption, .leftOption: return "⌥"
        case .fnControl: return "fn⌃"
        case .fn: return ""
        case .none: return "—"
        }
    }

    /// Whether this hotkey requires multiple modifier keys pressed together
    var isCombo: Bool {
        switch self {
        case .leftControlOption, .rightControlOption, .leftControlCommand, .fnControl: return true
        default: return false
        }
    }

    /// For single-key options: the key code
    var keyCode: UInt16? {
        switch self {
        case .rightControl: return 0x3E
        case .leftControl: return 0x3B
        case .rightOption: return 0x3D
        case .leftOption: return 0x3A
        case .fn: return 0x3F
        default: return nil
        }
    }

    /// For single-key options: the CGEventFlags mask to check
    var cgFlag: CGEventFlags? {
        switch self {
        case .rightControl, .leftControl: return .maskControl
        case .rightOption, .leftOption: return .maskAlternate
        case .fn: return .maskSecondaryFn
        default: return nil
        }
    }

    /// For combo options: the required keys and their corresponding flags
    var comboKeys: [(keyCode: UInt16, flag: CGEventFlags)]? {
        switch self {
        case .leftControlOption: return [(0x3B, .maskControl), (0x3A, .maskAlternate)]
        case .rightControlOption: return [(0x3E, .maskControl), (0x3D, .maskAlternate)]
        case .leftControlCommand: return [(0x3B, .maskControl), (0x37, .maskCommand)]
        case .fnControl: return [(0x3F, .maskSecondaryFn), (0x3B, .maskControl)]
        default: return nil
        }
    }
}

// MARK: - HotkeyManager

/// Manages global hotkey for recording with multi-mode support:
/// - Quick tap (< 500ms): toggle recording on/off (hands-free)
/// - Long press (> 500ms): push-to-talk (hold to record, release to stop)
/// - Hold hotkey + press AI Reply key: switch to AI Reply mode (screenshot + voice -> LLM -> paste)
class HotkeyManager {
    var onStartRecording: (() -> Void)?
    var onStopRecording: (() -> Void)?
    var onCancelRecording: (() -> Void)?
    var onStartAIReply: (() -> Void)?
    var onStopAIReply: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRetrying = false

    private var isKeyDown = false
    private var keyDownTime: TimeInterval?
    private var isHandsFreeMode = false
    private var isRecording = false
    private var comboKeysDown: Set<UInt16> = []
    private var lastEscTime: TimeInterval = 0
    private let doubleEscInterval: TimeInterval = 0.4

    private let briefPressThreshold: TimeInterval = 0.5

    // MARK: - AI Reply mode (hotkey + configurable key)
    /// Tracks which mode the current press activated
    enum ActiveMode { case none, stt, aiReply }
    private(set) var activeMode: ActiveMode = .none

    /// The key code that triggers AI Reply when pressed while hotkey is held (default: 'L' = 0x25)
    var aiReplyKeyCode: UInt16 {
        didSet { UserDefaults.standard.set(Int(aiReplyKeyCode), forKey: "aiReplyKeyCode") }
    }

    /// Dedicated hotkey for AI Agent mode (independent from STT hotkey)
    var selectedAIHotkey: HotkeyOption {
        didSet {
            UserDefaults.standard.set(selectedAIHotkey.rawValue, forKey: "selectedAIHotkey")
            setupEventTap()
        }
    }

    // AI Agent hotkey key-state (independent from STT hotkey state)
    private var aiIsKeyDown = false
    private var aiKeyDownTime: TimeInterval?
    private var aiComboKeysDown: Set<UInt16> = []

    var selectedHotkey: HotkeyOption {
        didSet {
            UserDefaults.standard.set(selectedHotkey.rawValue, forKey: "selectedHotkey")
            setupEventTap()
        }
    }

    init(onStart: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.onStartRecording = onStart
        self.onStopRecording = onStop

        let saved = UserDefaults.standard.string(forKey: "selectedHotkey") ?? HotkeyOption.leftControlOption.rawValue
        self.selectedHotkey = HotkeyOption(rawValue: saved) ?? .leftControlOption

        // AI Reply trigger key (default: 'L' = keyCode 0x25 = 37)
        let savedKeyCode = UserDefaults.standard.integer(forKey: "aiReplyKeyCode")
        self.aiReplyKeyCode = savedKeyCode > 0 ? UInt16(savedKeyCode) : 0x25

        // AI Agent dedicated hotkey (default: none/disabled)
        let savedAI = UserDefaults.standard.string(forKey: "selectedAIHotkey") ?? HotkeyOption.none.rawValue
        self.selectedAIHotkey = HotkeyOption(rawValue: savedAI) ?? .none

        requestAccessibilityIfNeeded()
        setupEventTap()
    }

    deinit {
        isRetrying = false
        removeEventTap()
    }

    /// Prompt user for Accessibility permission (adds app to the list automatically).
    private func requestAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            print("HotkeyManager: Accessibility not granted yet, will retry...")
        }
    }

    // MARK: - CGEvent Tap

    private func removeEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        resetState()
    }

    /// Force re-create the event tap. Called externally to recover from stale taps.
    func refreshEventTap() {
        setupEventTap()
    }

    private func setupEventTap() {
        removeEventTap()

        guard selectedHotkey != .none else { return }

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo!).takeUnretainedValue()

            // Re-enable tap if system disabled it (e.g. after permission change or timeout)
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                print("HotkeyManager: Tap was disabled by system, re-enabling...")
                if let tap = manager.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            if type == .keyDown {
                manager.handleKeyDownEvent(event)
            } else {
                manager.handleFlagsChanged(event)
            }
            return Unmanaged.passUnretained(event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            print("HotkeyManager: Failed to create event tap. Will retry...")
            scheduleRetry()
            return
        }
        isRetrying = false

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("HotkeyManager: Listening for \(selectedHotkey.displayName)")
    }

    /// Schedule a retry of setupEventTap using DispatchQueue.
    private func scheduleRetry() {
        guard !isRetrying else { return }
        isRetrying = true
        retryEventTap()
    }

    private func retryEventTap() {
        guard isRetrying, eventTap == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, self.isRetrying, self.eventTap == nil else { return }
            print("HotkeyManager: Retrying event tap setup...")
            self.setupEventTap()
            // If still no tap, setupEventTap will call scheduleRetry -> retryEventTap again
            if self.eventTap == nil && self.isRetrying {
                self.retryEventTap()
            }
        }
    }

    private func resetState() {
        isKeyDown = false
        keyDownTime = nil
        comboKeysDown.removeAll()
        aiIsKeyDown = false
        aiKeyDownTime = nil
        aiComboKeysDown.removeAll()
        // Only reset recording mode state when not actively recording.
        // Event tap refreshes can happen during recording (e.g. from the
        // post-launch retry timers) — clearing mode state while recording
        // leaves isRecording=true with activeMode=.none, a stuck state.
        if !isRecording {
            isHandsFreeMode = false
            activeMode = .none
        }
    }

    // MARK: - Event Handling

    private func handleKeyDownEvent(_ event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        print("HotkeyManager: keyDown code=\(keyCode) (0x\(String(keyCode, radix: 16))) isRecording=\(isRecording) activeMode=\(activeMode) aiReplyKey=\(aiReplyKeyCode)")

        // ESC = 0x35 (53) -- double-press to cancel recording (works in both STT and AI Agent modes)
        if keyCode == 0x35 && isRecording {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastEscTime <= doubleEscInterval {
                lastEscTime = 0
                isRecording = false
                isHandsFreeMode = false
                isKeyDown = false
                keyDownTime = nil
                aiIsKeyDown = false
                aiKeyDownTime = nil
                aiComboKeysDown.removeAll()
                let previousMode = activeMode
                activeMode = .none
                print("HotkeyManager: double-ESC cancel (was \(previousMode))")
                DispatchQueue.main.async { [weak self] in
                    self?.onCancelRecording?()
                }
            } else {
                lastEscTime = now
            }
            return
        }

        // AI Reply trigger: Ctrl+Option+L pressed together (or L pressed while hotkey held)
        // Check the event's modifier flags directly so simultaneous key presses work reliably.
        if keyCode == aiReplyKeyCode {
            let flags = event.flags
            let hasModifiers: Bool
            if selectedHotkey.isCombo, let comboKeys = selectedHotkey.comboKeys {
                hasModifiers = comboKeys.allSatisfy { flags.contains($0.flag) }
            } else if let targetFlag = selectedHotkey.cgFlag {
                hasModifiers = flags.contains(targetFlag)
            } else {
                hasModifiers = false
            }

            if hasModifiers {
                if isRecording && activeMode == .stt {
                    // Already recording STT — switch to AI Reply
                    print("HotkeyManager: AI Reply key pressed during STT, switching to AI Reply mode")
                    activeMode = .aiReply
                    DispatchQueue.main.async { [weak self] in
                        self?.onCancelRecording?()
                        self?.onStartAIReply?()
                    }
                } else if !isRecording {
                    // Direct Ctrl+Option+L press — start AI Reply directly
                    print("HotkeyManager: AI Reply combo detected (direct), starting AI Reply mode")
                    activeMode = .aiReply
                    isRecording = true
                    isKeyDown = true
                    keyDownTime = ProcessInfo.processInfo.systemUptime
                    // Pre-populate comboKeysDown so modifier release is detected properly
                    if let comboKeys = selectedHotkey.comboKeys {
                        for key in comboKeys {
                            comboKeysDown.insert(key.keyCode)
                        }
                    }
                    DispatchQueue.main.async { [weak self] in
                        self?.onStartAIReply?()
                    }
                }
            }
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // --- Process STT hotkey ---
        if selectedHotkey.isCombo {
            handleComboFlagsChanged(event, keyCode: keyCode)
        } else if let targetKeyCode = selectedHotkey.keyCode,
                  let targetFlag = selectedHotkey.cgFlag {
            let flagActive = event.flags.contains(targetFlag)
            let isOurKey = (keyCode == targetKeyCode)

            if flagActive && isOurKey && !isKeyDown {
                isKeyDown = true
                keyDownTime = ProcessInfo.processInfo.systemUptime
                handleKeyDown()
            } else if !flagActive && isKeyDown {
                let pressDuration: TimeInterval
                if let startTime = keyDownTime {
                    pressDuration = ProcessInfo.processInfo.systemUptime - startTime
                } else {
                    pressDuration = 1.0
                }
                isKeyDown = false
                keyDownTime = nil
                handleKeyUp(pressDuration: pressDuration)
            }
        }

        // --- Process AI Agent hotkey (independent state machine) ---
        if selectedAIHotkey != .none {
            if selectedAIHotkey.isCombo {
                handleAIComboFlagsChanged(event, keyCode: keyCode)
            } else if let targetKeyCode = selectedAIHotkey.keyCode,
                      let targetFlag = selectedAIHotkey.cgFlag {
                let flagActive = event.flags.contains(targetFlag)
                let isOurKey = (keyCode == targetKeyCode)

                if flagActive && isOurKey && !aiIsKeyDown {
                    aiIsKeyDown = true
                    aiKeyDownTime = ProcessInfo.processInfo.systemUptime
                    handleAIKeyDown()
                } else if !flagActive && aiIsKeyDown {
                    let pressDuration: TimeInterval
                    if let startTime = aiKeyDownTime {
                        pressDuration = ProcessInfo.processInfo.systemUptime - startTime
                    } else {
                        pressDuration = 1.0
                    }
                    aiIsKeyDown = false
                    aiKeyDownTime = nil
                    handleAIKeyUp(pressDuration: pressDuration)
                }
            }
        }
    }

    private func handleComboFlagsChanged(_ event: CGEvent, keyCode: UInt16) {
        guard let comboKeys = selectedHotkey.comboKeys else { return }

        // Only process events for keys in our combo
        guard let matchedKey = comboKeys.first(where: { $0.keyCode == keyCode }) else { return }

        let flagActive = event.flags.contains(matchedKey.flag)
        if flagActive {
            comboKeysDown.insert(keyCode)
        } else {
            comboKeysDown.remove(keyCode)
        }

        let allDown = comboKeys.allSatisfy { comboKeysDown.contains($0.keyCode) }

        if allDown && !isKeyDown {
            // All combo keys pressed
            isKeyDown = true
            keyDownTime = ProcessInfo.processInfo.systemUptime
            handleKeyDown()
        } else if !allDown && isKeyDown {
            // At least one combo key released
            let pressDuration: TimeInterval
            if let startTime = keyDownTime {
                pressDuration = ProcessInfo.processInfo.systemUptime - startTime
            } else {
                pressDuration = 1.0
            }
            isKeyDown = false
            keyDownTime = nil
            handleKeyUp(pressDuration: pressDuration)
        }
    }

    private func handleKeyDown() {
        if isHandsFreeMode {
            // In hands-free mode, next press stops recording
            isHandsFreeMode = false
            isRecording = false
            let stoppingMode = activeMode
            activeMode = .none
            DispatchQueue.main.async { [weak self] in
                if stoppingMode == .aiReply {
                    self?.onStopAIReply?()
                } else {
                    self?.onStopRecording?()
                }
            }
            return
        }

        if !isRecording {
            // Start normal STT mode (AI Reply is triggered by pressing the AI key during recording)
            activeMode = .stt
            isRecording = true
            DispatchQueue.main.async { [weak self] in
                self?.onStartRecording?()
            }
        }
    }

    private func handleKeyUp(pressDuration: TimeInterval) {
        if !isRecording {
            return
        }

        if pressDuration < briefPressThreshold {
            // Quick tap -> hands-free mode (recording continues until next tap)
            isHandsFreeMode = true
        } else {
            // Long press -> PTT release, stop recording
            isRecording = false
            isHandsFreeMode = false
            let stoppingMode = activeMode
            activeMode = .none
            DispatchQueue.main.async { [weak self] in
                if stoppingMode == .aiReply {
                    self?.onStopAIReply?()
                } else {
                    self?.onStopRecording?()
                }
            }
        }
    }

    // MARK: - AI Agent Hotkey Handlers

    private func handleAIComboFlagsChanged(_ event: CGEvent, keyCode: UInt16) {
        guard let comboKeys = selectedAIHotkey.comboKeys else { return }
        guard let matchedKey = comboKeys.first(where: { $0.keyCode == keyCode }) else { return }

        let flagActive = event.flags.contains(matchedKey.flag)
        if flagActive {
            aiComboKeysDown.insert(keyCode)
        } else {
            aiComboKeysDown.remove(keyCode)
        }

        let allDown = comboKeys.allSatisfy { aiComboKeysDown.contains($0.keyCode) }
        print("HotkeyManager[AI]: flagsChanged key=0x\(String(keyCode, radix: 16)) active=\(flagActive) aiKeysDown=\(aiComboKeysDown) allDown=\(allDown) aiIsKeyDown=\(aiIsKeyDown)")

        if allDown && !aiIsKeyDown {
            aiIsKeyDown = true
            aiKeyDownTime = ProcessInfo.processInfo.systemUptime
            handleAIKeyDown()
        } else if !allDown && aiIsKeyDown {
            let pressDuration: TimeInterval
            if let startTime = aiKeyDownTime {
                pressDuration = ProcessInfo.processInfo.systemUptime - startTime
            } else {
                pressDuration = 1.0
            }
            aiIsKeyDown = false
            aiKeyDownTime = nil
            handleAIKeyUp(pressDuration: pressDuration)
        }
    }

    private func handleAIKeyDown() {
        print("HotkeyManager[AI]: handleAIKeyDown isRecording=\(isRecording) activeMode=\(activeMode)")
        if isRecording && activeMode == .aiReply {
            // Second press: stop AI recording and generate
            isRecording = false
            activeMode = .none
            print("HotkeyManager[AI]: toggle OFF — stopping AI recording")
            DispatchQueue.main.async { [weak self] in
                self?.onStopAIReply?()
            }
        } else if !isRecording && activeMode == .none {
            // First press: start AI recording
            activeMode = .aiReply
            isRecording = true
            print("HotkeyManager[AI]: toggle ON — starting AI recording")
            DispatchQueue.main.async { [weak self] in
                self?.onStartAIReply?()
            }
        }
    }

    private func handleAIKeyUp(pressDuration: TimeInterval) {
        // AI hotkey is toggle-based: press to start, press again to stop.
        // Release has no effect.
    }

    /// Called externally when recording is stopped (e.g. from menu button)
    func notifyRecordingStopped() {
        isRecording = false
        isHandsFreeMode = false
        activeMode = .none
    }
}
