import AppKit
import ApplicationServices
import Carbon

// MARK: - Hotkey Options

enum HotkeyOption: String, CaseIterable, Identifiable {
    case leftControlOption = "leftControlOption"
    case rightControlOption = "rightControlOption"
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
        case .leftControlOption, .rightControlOption, .fnControl: return true
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
        case .fnControl: return [(0x3F, .maskSecondaryFn), (0x3B, .maskControl)]
        default: return nil
        }
    }
}

// MARK: - HotkeyManager

/// Manages global hotkey for recording with dual-mode support:
/// - Quick tap (< 500ms): toggle recording on/off
/// - Long press (> 500ms): push-to-talk (hold to record, release to stop)
class HotkeyManager {
    var onStartRecording: (() -> Void)?
    var onStopRecording: (() -> Void)?
    var onCancelRecording: (() -> Void)?

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
            // If still no tap, setupEventTap will call scheduleRetry → retryEventTap again
            if self.eventTap == nil && self.isRetrying {
                self.retryEventTap()
            }
        }
    }

    private func resetState() {
        isKeyDown = false
        keyDownTime = nil
        isHandsFreeMode = false
        comboKeysDown.removeAll()
    }

    // MARK: - Event Handling

    private func handleKeyDownEvent(_ event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        // ESC = 0x35 (53) — double-press to cancel recording
        if keyCode == 0x35 && isRecording {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastEscTime <= doubleEscInterval {
                lastEscTime = 0
                isRecording = false
                isHandsFreeMode = false
                isKeyDown = false
                keyDownTime = nil
                DispatchQueue.main.async { [weak self] in
                    self?.onCancelRecording?()
                }
            } else {
                lastEscTime = now
            }
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        if selectedHotkey.isCombo {
            handleComboFlagsChanged(event, keyCode: keyCode)
            return
        }

        guard let targetKeyCode = selectedHotkey.keyCode,
              let targetFlag = selectedHotkey.cgFlag else { return }

        let flagActive = event.flags.contains(targetFlag)
        let isOurKey = (keyCode == targetKeyCode)

        if flagActive && isOurKey && !isKeyDown {
            // Key down
            isKeyDown = true
            keyDownTime = ProcessInfo.processInfo.systemUptime
            handleKeyDown()
        } else if !flagActive && isKeyDown {
            // Key up
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
            DispatchQueue.main.async { [weak self] in
                self?.onStopRecording?()
            }
            return
        }

        if !isRecording {
            isRecording = true
            DispatchQueue.main.async { [weak self] in
                self?.onStartRecording?()
            }
        }
    }

    private func handleKeyUp(pressDuration: TimeInterval) {
        if !isRecording {
            // Not recording, nothing to do
            return
        }

        if pressDuration < briefPressThreshold {
            // Quick tap → hands-free mode (recording continues until next tap)
            isHandsFreeMode = true
        } else {
            // Long press → PTT release, stop recording
            isRecording = false
            isHandsFreeMode = false
            DispatchQueue.main.async { [weak self] in
                self?.onStopRecording?()
            }
        }
    }

    /// Called externally when recording is stopped (e.g. from menu button)
    func notifyRecordingStopped() {
        isRecording = false
        isHandsFreeMode = false
    }
}
