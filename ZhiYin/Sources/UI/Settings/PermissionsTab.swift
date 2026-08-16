import SwiftUI
import AVFoundation

// MARK: - Permissions Tab

struct PermissionsTab: View {
    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var screenGranted = false
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("App Permissions")
                    .font(.title2.bold())
                Text("ZhiYin requires the following permissions to function properly")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)

            SettingsSection("Required Permissions") {
                PermissionRow(
                    icon: "mic.fill",
                    iconColor: .green,
                    title: "Microphone Access",
                    description: "Allow ZhiYin to record your voice for transcription",
                    isGranted: micGranted,
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                    onRefresh: { refreshPermissions() }
                )

                Divider()

                PermissionRow(
                    icon: "hand.raised.fill",
                    iconColor: .orange,
                    title: "Accessibility Access",
                    description: "Allow ZhiYin to use global hotkeys and paste text at cursor",
                    isGranted: accessibilityGranted,
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                    onRefresh: { refreshPermissions() }
                )

                Divider()

                PermissionRow(
                    icon: "rectangle.dashed.badge.record",
                    iconColor: .blue,
                    title: "Screen & System Audio Recording",
                    description: "Allow ZhiYin to capture the active window as context for AI Agent replies",
                    isGranted: screenGranted,
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                    onRefresh: { refreshPermissions() }
                )
            }

            if !micGranted || !accessibilityGranted || !screenGranted {
                SettingsSection("Tips") {
                    Label("Accessibility may require restarting ZhiYin after granting", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            refreshPermissions()
            startPolling()
        }
        .onDisappear {
            stopPolling()
        }
    }

    private func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = TextInjector.hasAccessibilityPermission()
        screenGranted = CGPreflightScreenCaptureAccess()
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            refreshPermissions()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

struct PermissionRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    let isGranted: Bool
    let settingsURL: String
    let onRefresh: () -> Void

    private var activeColor: Color { isGranted ? .green : iconColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(activeColor.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 16))
                        .foregroundStyle(activeColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Refresh status")

                if isGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.red)
                }
            }

            if !isGranted {
                Button(action: {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack {
                        Text("Open System Settings")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}
