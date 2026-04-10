import AppKit
import Carbon

/// Injects recognized text into the currently focused application
class TextInjector {

    private static func log(_ msg: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(ts)] \(msg)\n"
        print("TextInjector: \(msg)")
        if let data = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/zhiyin-injector.log")
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            } else {
                try? data.write(to: url)
            }
        }
    }

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

        // Set transcription text with transient flag via NSPasteboardItem
        // (TransientType tells clipboard managers like Paste/Maccy not to record this)
        pasteboard.clearContents()
        let pasteItem = NSPasteboardItem()
        pasteItem.setString(text, forType: .string)
        pasteItem.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.writeObjects([pasteItem])
        Self.log("clipboard set, text length=\(text.count), changeCount=\(pasteboard.changeCount)")

        // Verify clipboard was actually set
        let verify = pasteboard.string(forType: .string)
        Self.log("clipboard verify: \(verify == text ? "OK" : "MISMATCH: got \(verify?.prefix(50) ?? "nil")")")

        // 50ms delay: let pasteboard write propagate before simulating Cmd+V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Self.log("simulating Cmd+V now, changeCount=\(pasteboard.changeCount)")
            self.simulatePaste()
            Self.log("Cmd+V posted")
        }

        // Restore original clipboard after 2s (give target app plenty of time to process)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            Self.log("restoring original clipboard (savedItems=\(savedItems.count))")
            pasteboard.clearContents()
            for itemDict in savedItems {
                let item = NSPasteboardItem()
                for (type, data) in itemDict {
                    item.setData(data, forType: type)
                }
                pasteboard.writeObjects([item])
            }
        }

        Self.log("injectText scheduled, text=\(text)")
        return true
    }

    /// Simulate Cmd+V paste with proper key sequence and privateState source
    private func simulatePaste() {
        let source = CGEventSource(stateID: .privateState)

        // Cmd down → V down → V up → Cmd up (full modifier sequence)
        if let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true) {
            cmdDown.flags = .maskCommand
            cmdDown.post(tap: .cghidEventTap)
        }
        if let vDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) {
            vDown.flags = .maskCommand
            vDown.post(tap: .cghidEventTap)
        }
        if let vUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) {
            vUp.flags = .maskCommand
            vUp.post(tap: .cghidEventTap)
        }
        if let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) {
            cmdUp.post(tap: .cghidEventTap)
        }
    }
}
