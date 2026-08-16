import SwiftUI

// MARK: - License Tab

struct LicenseTab: View {
    @AppStorage("licenseKey") private var licenseKey = ""
    @AppStorage("isPro") private var isPro = false
    @StateObject private var usage = UsageTracker.shared
    @StateObject private var updater = UpdateChecker.shared
    @StateObject private var licenseManager = LicenseManager.shared
    @State private var keyInput = ""
    @State private var isChecking = false
    @State private var checkResult: String? = nil

    private static let zhiyinGreen = Color(red: 0.35, green: 0.78, blue: 0.48)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if isPro {
                // Pro user view
                SettingsSection("License") {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title2)
                            .foregroundStyle(Self.zhiyinGreen)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("ZhiYin")
                                    .font(.headline)
                                Text("PRO")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .foregroundStyle(.white)
                                    .background(Self.zhiyinGreen, in: RoundedRectangle(cornerRadius: 4))
                            }
                            Text("Lifetime · Unlimited transcriptions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Manage License") {
                            NSWorkspace.shared.open(LicenseManager.customerPortalURL)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button("Deactivate") {
                            Task { await licenseManager.deactivate() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

            } else {
                // Free user view
                SettingsSection("Free Tier Usage") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Today: \(usage.todayCount) / \(UsageTracker.dailyFreeLimit)")
                                .font(.callout)
                            Text("\(usage.remaining) transcriptions remaining")
                                .font(.caption)
                                .foregroundStyle(usage.isOverLimit ? .red : .secondary)
                        }
                        Spacer()
                        ProgressView(value: min(Double(usage.todayCount), Double(UsageTracker.dailyFreeLimit)),
                                     total: Double(UsageTracker.dailyFreeLimit))
                            .frame(width: 100)
                            .tint(usage.isOverLimit ? .red : .accentColor)
                    }
                }

                SettingsSection("Activate License") {
                    activationView
                }

                SettingsSection("Get Pro") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Unlimited transcriptions, no daily limits")
                                .font(.callout)
                            Text("One-time purchase · Lifetime")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Buy Pro — $12") {
                            NSWorkspace.shared.open(LicenseManager.checkoutURL)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                SettingsSection("Already purchased?") {
                    HStack {
                        Text("Manage your license and device activations")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("License Management Portal") {
                            NSWorkspace.shared.open(LicenseManager.customerPortalURL)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            // Updates section visible to ALL users (Bug #2)
            updatesSection
        }
    }

    private var updatesSection: some View {
        SettingsSection("Updates") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current version: \(UpdateChecker.currentVersion)")
                        .font(.callout)
                    if let result = checkResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(updater.hasUpdate ? Self.zhiyinGreen : .secondary)
                    } else if updater.hasUpdate, let version = updater.latestVersion {
                        Text("v\(version) available")
                            .font(.caption)
                            .foregroundStyle(Self.zhiyinGreen)
                    } else {
                        Text("You're up to date")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(isChecking ? "Checking..." : "Check for Updates") {
                    Task {
                        isChecking = true
                        checkResult = nil
                        await UpdateChecker.shared.check()
                        isChecking = false
                        if updater.hasUpdate, let v = updater.latestVersion {
                            checkResult = "Update available: v\(v)"
                        } else {
                            checkResult = "You're up to date (v\(UpdateChecker.currentVersion))"
                        }
                        // Auto-clear inline result after 5 seconds so the section returns to its default state
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        checkResult = nil
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isChecking)
            }
        }
    }

    private var activationView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Enter License Key", text: $keyInput)
                    .textFieldStyle(.roundedBorder)
                Button(licenseManager.isActivating ? "Verifying..." : "Activate") {
                    Task {
                        let success = await licenseManager.activate(key: keyInput)
                        if success { keyInput = "" }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(keyInput.isEmpty || licenseManager.isActivating)
            }

            if !licenseManager.errorMessage.isEmpty {
                Text(licenseManager.errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }
}
