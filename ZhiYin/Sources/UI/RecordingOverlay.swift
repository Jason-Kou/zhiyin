import SwiftUI
import AppKit

/// Floating pill overlay at bottom center of screen, WeChat-style
class RecordingOverlayController {
    static let shared = RecordingOverlayController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<RecordingOverlayView>?
    private let viewModel = RecordingOverlayViewModel()

    /// WeChat-style green
    static let accentColor = NSColor(red: 0.35, green: 0.78, blue: 0.48, alpha: 1.0)

    func show() {
        viewModel.text = ""
        viewModel.state = .recording

        if window == nil {
            createWindow()
        }
        updatePosition()
        window?.orderFront(nil)

        // Animate in
        window?.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            window?.animator().alphaValue = 1
        }
    }

    func updateText(_ text: String) {
        DispatchQueue.main.async {
            self.viewModel.text = text
            self.updatePosition()
        }
    }

    func showTranscribing() {
        DispatchQueue.main.async {
            self.viewModel.state = .transcribing
            self.updatePosition()
        }
    }

    func showForceStopped(message: String) {
        DispatchQueue.main.async {
            self.viewModel.state = .forceStopped(message: message)
            self.viewModel.text = ""
            self.updatePosition()
        }
    }

    func dismiss() {
        DispatchQueue.main.async {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                self.window?.animator().alphaValue = 0
            }, completionHandler: {
                self.window?.orderOut(nil)
                self.viewModel.text = ""
                self.viewModel.state = .recording
            })
        }
    }

    private func createWindow() {
        let overlayView = RecordingOverlayView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: overlayView)
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 52)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 52),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.isMovableByWindowBackground = false
        w.ignoresMouseEvents = true
        w.contentView = hosting

        self.hostingView = hosting
        self.window = w
    }

    private func updatePosition() {
        guard let window = window, let screen = NSScreen.main else { return }

        // Let SwiftUI calculate the ideal size
        hostingView?.invalidateIntrinsicContentSize()
        let fittingSize = hostingView?.fittingSize ?? NSSize(width: 300, height: 52)
        let width = min(max(fittingSize.width + 16, 64), 420)
        let height = fittingSize.height + 8

        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - width / 2
        let y = screenFrame.origin.y + 40  // 40pt above bottom

        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

// MARK: - ViewModel

class RecordingOverlayViewModel: ObservableObject {
    enum State {
        case recording
        case transcribing
        case forceStopped(message: String)
    }
    @Published var text: String = ""
    @Published var state: State = .recording
}

// MARK: - SwiftUI View

struct RecordingOverlayView: View {
    @ObservedObject var viewModel: RecordingOverlayViewModel

    /// WeChat green
    private let pillColor = Color(red: 0.35, green: 0.78, blue: 0.48)

    var body: some View {
        HStack(spacing: 8) {
            switch viewModel.state {
            case .recording:
                RecordingMicIcon()
                if !viewModel.text.isEmpty {
                    Text(viewModel.text)
                        .foregroundColor(.white)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            case .transcribing:
                ProgressView()
                    .scaleEffect(0.7)
                    .colorScheme(.dark)
                if !viewModel.text.isEmpty {
                    Text(viewModel.text)
                        .foregroundColor(.white)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.head)
                } else {
                    Text("Transcribing...")
                        .foregroundColor(.white.opacity(0.85))
                        .font(.system(size: 14, weight: .medium))
                }
            case .forceStopped(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.white)
                    .font(.system(size: 14))
                Text(message)
                    .foregroundColor(.white)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: 400)
        .background(
            Capsule()
                .fill(pillColor)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        )
    }
}

// MARK: - Animated Mic Icon

struct RecordingMicIcon: View {
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            // Pulse ring
            Circle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 28, height: 28)
                .scaleEffect(isPulsing ? 1.3 : 1.0)
                .opacity(isPulsing ? 0 : 0.5)
                .animation(
                    .easeInOut(duration: 1.0).repeatForever(autoreverses: false),
                    value: isPulsing
                )

            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: 28, height: 28)
        .onAppear { isPulsing = true }
    }
}
