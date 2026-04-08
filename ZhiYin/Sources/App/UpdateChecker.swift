import Foundation

extension Notification.Name {
    static let zhiyinUpdateFound = Notification.Name("zhiyinUpdateFound")
}

/// Checks GitHub Releases for new versions on startup.
/// Simple DIY approach — no Sparkle dependency.
class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    static let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    private let repoOwner = "Jason-Kou"
    private let repoName = "zhiyin"

    @Published var latestVersion: String?
    @Published var downloadURL: String?
    @Published var hasUpdate = false

    private var apiURL: URL {
        URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
    }

    var releasesPageURL: URL {
        URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases")!
    }

    /// Check for updates. Call on app launch.
    /// Self-retries up to `attempts` times on transient failure (network throw, non-200, missing tag_name).
    /// A successful 200 response with a valid tag_name is considered terminal — no retry, even if "no update".
    func check(attempts: Int = 3) async {
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        // Fetch + parse. Any failure here falls through to the retry block below.
        var parsedRemote: String?
        var parsedAssets: [[String: Any]]?
        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tagName = json["tag_name"] as? String {
                // Strip leading "v" if present (e.g. "v0.7.0" → "0.7.0")
                parsedRemote = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
                parsedAssets = json["assets"] as? [[String: Any]]
            }
        } catch {
            // Silently fail — update check is non-critical
            print("UpdateChecker: \(error.localizedDescription)")
        }

        // Success path: we got a valid remote version string
        if let remote = parsedRemote {
            if isNewer(remote: remote, local: Self.currentVersion) {
                // Find DMG asset URL, fallback to releases page
                var resolvedDownloadURL: String? = nil
                if let assets = parsedAssets {
                    for asset in assets {
                        if let name = asset["name"] as? String,
                           name.hasSuffix(".dmg"),
                           let url = asset["browser_download_url"] as? String {
                            resolvedDownloadURL = url
                            break
                        }
                    }
                }
                if resolvedDownloadURL == nil {
                    resolvedDownloadURL = releasesPageURL.absoluteString
                }
                await MainActor.run {
                    latestVersion = remote
                    downloadURL = resolvedDownloadURL
                    hasUpdate = true
                }
                // Bug #4 foundation: notify interested observers (e.g. AppDelegate status menu)
                NotificationCenter.default.post(name: .zhiyinUpdateFound, object: nil)
            } else {
                // Bug #5: reset stale state on confirmed "no update"
                await MainActor.run {
                    hasUpdate = false
                    latestVersion = nil
                    downloadURL = nil
                }
            }
            return
        }

        // Failure path: preserve any previously-detected update across transient errors
        if attempts > 1 {
            let delaySeconds: UInt64 = attempts == 3 ? 10 : 30  // first retry at +10s, second at +30s
            print("UpdateChecker: retrying in \(delaySeconds)s (attempts left: \(attempts - 1))")
            try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            await check(attempts: attempts - 1)
        }
    }

    /// Compare semantic versions. Returns true if remote > local.
    private func isNewer(remote: String, local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }
}
