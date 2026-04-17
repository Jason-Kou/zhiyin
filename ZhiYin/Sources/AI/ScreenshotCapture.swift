import ScreenCaptureKit
import AppKit

/// Errors that can occur during screenshot capture and encoding.
enum ScreenshotError: Error, LocalizedError {
    case noDisplay
    case captureFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No displays found for screenshot capture"
        case .captureFailed:
            return "ScreenCaptureKit failed to capture the screen"
        case .encodingFailed:
            return "Failed to encode screenshot as PNG"
        }
    }
}

/// Captures full-screen screenshots using ScreenCaptureKit and encodes them as base64 PNG strings.
class ScreenshotCapture {
    static let shared = ScreenshotCapture()

    /// Captures the frontmost window as a CGImage.
    /// Falls back to full screen if window capture fails.
    func captureFullScreen() async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let display = content.displays.first else {
            print("ScreenshotCapture: no displays found")
            throw ScreenshotError.noDisplay
        }

        // Try to capture the frontmost window instead of the entire screen
        if let frontWindow = findFrontmostWindow(in: content) {
            do {
                let filter = SCContentFilter(desktopIndependentWindow: frontWindow)
                let config = SCStreamConfiguration()
                // Use Retina (2x) resolution, capped at 1920px output width
                let retinaScale = NSScreen.main?.backingScaleFactor ?? 2.0
                let nativeWidth = Double(frontWindow.frame.width) * retinaScale
                let nativeHeight = Double(frontWindow.frame.height) * retinaScale
                let maxWidth = 1920.0
                let downscale = min(1.0, maxWidth / nativeWidth)
                config.width = Int(nativeWidth * downscale)
                config.height = Int(nativeHeight * downscale)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.captureResolution = .best

                print("ScreenshotCapture: capturing window '\(frontWindow.title ?? "untitled")' (\(frontWindow.owningApplication?.applicationName ?? "unknown")) \(Int(frontWindow.frame.width))x\(Int(frontWindow.frame.height)) @\(retinaScale)x → \(config.width)x\(config.height)")

                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                print("ScreenshotCapture: window capture succeeded")
                return image
            } catch {
                print("ScreenshotCapture: window capture failed, falling back to full screen - \(error.localizedDescription)")
            }
        }

        // Fallback: capture the full display
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let maxWidth = 1280
        let scale = min(1.0, Double(maxWidth) / Double(display.width))
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.captureResolution = .nominal

        print("ScreenshotCapture: capturing full display \(display.width)x\(display.height) → \(config.width)x\(config.height)")

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            print("ScreenshotCapture: full screen capture succeeded")
            return image
        } catch {
            print("ScreenshotCapture: capture failed - \(error.localizedDescription)")
            throw ScreenshotError.captureFailed
        }
    }

    /// Finds the frontmost window (excluding ZhiYin itself and system UI elements).
    private func findFrontmostWindow(in content: SCShareableContent) -> SCWindow? {
        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.zhiyin.app"
        let ignoredBundleIDs: Set<String> = [
            ownBundleID,
            "com.apple.controlcenter",
            "com.apple.notificationcenterui",
            "com.apple.dock",
            "com.apple.WindowManager",
        ]

        // Get the frontmost app from NSWorkspace
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            print("ScreenshotCapture: no frontmost application found")
            return nil
        }

        let frontBundleID = frontApp.bundleIdentifier ?? ""
        print("ScreenshotCapture: frontmost app = \(frontApp.localizedName ?? "unknown") (\(frontBundleID))")

        // Skip if frontmost is ZhiYin itself or system UI
        if ignoredBundleIDs.contains(frontBundleID) {
            print("ScreenshotCapture: frontmost app is ignored, using full screen")
            return nil
        }

        // Find the largest on-screen window from the frontmost app
        let candidates = content.windows.filter { window in
            guard let app = window.owningApplication else { return false }
            return app.bundleIdentifier == frontBundleID
                && window.isOnScreen
                && window.frame.width > 100
                && window.frame.height > 100
        }

        let best = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })

        if let w = best {
            print("ScreenshotCapture: selected window '\(w.title ?? "")' \(Int(w.frame.width))x\(Int(w.frame.height))")
        } else {
            print("ScreenshotCapture: no suitable window found for \(frontBundleID)")
        }
        return best
    }

    /// Encodes a CGImage to a base64-encoded PNG string.
    /// Returns an empty string on failure.
    func encodeScreenshotToBase64(_ image: CGImage) -> String {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))

        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            print("ScreenshotCapture: JPEG encoding failed")
            return ""
        }

        #if DEBUG
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("zhiyin_screenshot.jpg")
        try? jpegData.write(to: tempURL)
        print("ScreenshotCapture: saved debug screenshot to \(tempURL.path)")
        #endif

        let base64 = jpegData.base64EncodedString()
        print("ScreenshotCapture: encoded \(jpegData.count / 1024)KB JPEG to base64 (\(base64.count) chars)")
        return base64
    }
}
