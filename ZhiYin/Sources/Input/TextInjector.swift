import AppKit
import Carbon

/// Injects recognized text into the currently focused application
class TextInjector {

    /// Check if we have accessibility permissions needed for key simulation
    static func hasAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Prompt user to grant accessibility permission if not already granted
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Inject text using pasteboard + Cmd+V.
    /// Saves and restores the original clipboard content after pasting.
    /// Returns true if injection was attempted, false if permissions missing.
    @discardableResult
    func injectText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        guard TextInjector.hasAccessibilityPermission() else {
            print("Accessibility permission not granted")
            TextInjector.requestAccessibilityPermission()
            return false
        }

        let pasteboard = NSPasteboard.general

        // Save current clipboard contents
        let savedItems: [[NSPasteboard.PasteboardType: Data]] = pasteboard.pasteboardItems?.compactMap { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict.isEmpty ? nil : dict
        } ?? []

        // Set transcription text and paste
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        simulateKeyPress(keyCode: 9, modifiers: .maskCommand)  // 9 = 'V' key

        // Restore original clipboard after paste completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pasteboard.clearContents()
            for itemDict in savedItems {
                let item = NSPasteboardItem()
                for (type, data) in itemDict {
                    item.setData(data, forType: type)
                }
                pasteboard.writeObjects([item])
            }
        }

        print("Text injected: \(text)")
        return true
    }

    /// Simulate a key press event
    private func simulateKeyPress(keyCode: CGKeyCode, modifiers: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            keyDown.flags = modifiers
            keyDown.post(tap: .cghidEventTap)
        }

        // Key up
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            keyUp.flags = modifiers
            keyUp.post(tap: .cghidEventTap)
        }
    }
}
