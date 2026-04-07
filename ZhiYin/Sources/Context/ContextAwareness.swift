import AppKit
import Foundation

/// Captures context from the current app: selected text and browser URL
class ContextAwareness {
    static let shared = ContextAwareness()

    struct Context {
        var selectedText: String?
        var currentURL: String?
        var appBundleID: String?
    }

    /// Capture context before recording starts
    func captureContext() -> Context {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleID = frontApp?.bundleIdentifier

        return Context(
            selectedText: getSelectedText(),
            currentURL: getBrowserURL(bundleID: bundleID),
            appBundleID: bundleID
        )
    }

    // MARK: - Selected Text via Accessibility API

    private func getSelectedText() -> String? {
        let systemElement = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(systemElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard focusResult == .success, let element = focusedElement else { return nil }

        var selectedTextValue: AnyObject?
        let textResult = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedTextValue)
        guard textResult == .success, let text = selectedTextValue as? String, !text.isEmpty else { return nil }

        return text
    }

    // MARK: - Browser URL via AppleScript

    private func getBrowserURL(bundleID: String?) -> String? {
        guard let bundleID = bundleID else { return nil }

        let script: String?
        switch bundleID {
        case "com.apple.Safari":
            script = "tell application \"Safari\" to get URL of current tab of front window"
        case "com.google.Chrome":
            script = "tell application \"Google Chrome\" to get URL of active tab of front window"
        case "com.brave.Browser":
            script = "tell application \"Brave Browser\" to get URL of active tab of front window"
        case "company.thebrowser.Browser":
            script = "tell application \"Arc\" to get URL of active tab of front window"
        case "org.mozilla.firefox":
            // Firefox doesn't support AppleScript URL retrieval well
            script = nil
        default:
            script = nil
        }

        guard let appleScript = script else { return nil }

        var error: NSDictionary?
        let scriptObject = NSAppleScript(source: appleScript)
        let result = scriptObject?.executeAndReturnError(&error)

        if let error = error {
            print("AppleScript error: \(error)")
            return nil
        }

        return result?.stringValue
    }
}
