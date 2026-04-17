import SwiftUI
import AppKit

/// Floating pill overlay at bottom center of screen, WeChat-style
class RecordingOverlayController {
    static let shared = RecordingOverlayController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<RecordingOverlayView>?
    private let viewModel = RecordingOverlayViewModel()
    private var toastDismissTimer: Timer?

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

    // MARK: - AI Reply overlay states

    func showAIRecording() {
        viewModel.text = ""
        viewModel.state = .aiRecording

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

    func showAIGenerating() {
        DispatchQueue.main.async {
            self.viewModel.text = ""
            self.viewModel.state = .aiGenerating
            self.updatePosition()
        }
    }

    func showAIError(message: String) {
        DispatchQueue.main.async {
            self.viewModel.state = .aiError(message: message)
            self.updatePosition()
        }
    }

    // MARK: - Transient Toasts

    /// Show a success or error toast for `duration` seconds, then auto-dismiss.
    /// Used by the "Copy Last" / "Retry Last" menu actions for quick feedback.
    func showToast(message: String, isError: Bool, duration: TimeInterval = 1.5) {
        DispatchQueue.main.async {
            self.toastDismissTimer?.invalidate()
            self.viewModel.text = ""
            self.viewModel.state = isError ? .toastError(message: message) : .toastSuccess(message: message)

            if self.window == nil {
                self.createWindow()
            }
            self.updatePosition()
            self.window?.orderFront(nil)
            self.window?.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self.window?.animator().alphaValue = 1
            }

            self.toastDismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        DispatchQueue.main.async {
            self.toastDismissTimer?.invalidate()
            self.toastDismissTimer = nil
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

        // Let SwiftUI calculate the ideal size.
        // layoutSubtreeIfNeeded forces a synchronous layout pass so fittingSize
        // reflects the latest @Published state — without it, state transitions
        // read the previous state's size and the window is sized for one state
        // behind.
        hostingView?.invalidateIntrinsicContentSize()
        hostingView?.layoutSubtreeIfNeeded()
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
        case recording                      // STT: recording voice
        case transcribing                   // STT: waiting for transcription
        case forceStopped(message: String)  // STT: force-stopped (time/memory)
        case aiRecording                    // AI Reply: recording voice
        case aiGenerating                   // AI Reply: waiting for LLM response
        case aiError(message: String)       // AI Reply: error state
        case toastSuccess(message: String)  // Transient success toast
        case toastError(message: String)    // Transient error toast
    }
    @Published var text: String = ""
    @Published var state: State = .recording

    /// Whether the current state is an AI Reply state
    var isAIState: Bool {
        switch state {
        case .aiRecording, .aiGenerating, .aiError: return true
        default: return false
        }
    }

    /// Whether the current state is a transient toast
    var isToastState: Bool {
        switch state {
        case .toastSuccess, .toastError: return true
        default: return false
        }
    }
}

// MARK: - SwiftUI View

struct RecordingOverlayView: View {
    @ObservedObject var viewModel: RecordingOverlayViewModel

    /// WeChat green for STT states
    private let pillColor = Color(red: 0.35, green: 0.78, blue: 0.48)
    /// Purple/blue for AI Reply states
    private let aiPillColor = Color(red: 0.45, green: 0.40, blue: 0.85)
    /// Neutral dark for transient success toasts
    private let toastSuccessColor = Color(red: 0.20, green: 0.55, blue: 0.35)
    /// Desaturated red for transient error toasts
    private let toastErrorColor = Color(red: 0.70, green: 0.25, blue: 0.25)

    /// Background color based on current state
    private var currentPillColor: Color {
        switch viewModel.state {
        case .toastSuccess: return toastSuccessColor
        case .toastError: return toastErrorColor
        default: return viewModel.isAIState ? aiPillColor : pillColor
        }
    }

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
            case .aiRecording:
                RecordingAIIcon()
                Text("AI Reply: Recording...")
                    .foregroundColor(.white)
                    .font(.system(size: 14, weight: .medium))
                if !viewModel.text.isEmpty {
                    Text(viewModel.text)
                        .foregroundColor(.white.opacity(0.85))
                        .font(.system(size: 12, weight: .regular))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            case .aiGenerating:
                ZStack {
                    ProgressView()
                        .scaleEffect(0.7)
                        .colorScheme(.dark)
                }
                .frame(width: 28, height: 28)
                Text("AI: Generating reply...")
                    .foregroundColor(.white.opacity(0.85))
                    .font(.system(size: 14, weight: .medium))
            case .aiError(let message):
                ZStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 16))
                }
                .frame(width: 28, height: 28)
                Text(message)
                    .foregroundColor(.white)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
            case .toastSuccess(let message):
                ZStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 16))
                }
                .frame(width: 28, height: 28)
                Text(message)
                    .foregroundColor(.white)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
            case .toastError(let message):
                ZStack {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 16))
                }
                .frame(width: 28, height: 28)
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
                .fill(currentPillColor)
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

// MARK: - Animated AI Icon

struct RecordingAIIcon: View {
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

            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: 28, height: 28)
        .onAppear { isPulsing = true }
    }
}
