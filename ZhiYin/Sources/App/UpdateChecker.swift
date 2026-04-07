import Foundation

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
    func check() async {
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

            guard let tagName = json["tag_name"] as? String else { return }

            // Strip leading "v" if present (e.g. "v0.7.0" → "0.7.0")
            let remote = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

            if isNewer(remote: remote, local: Self.currentVersion) {
                await MainActor.run {
                    latestVersion = remote
                    hasUpdate = true
                    // Find DMG asset URL, fallback to releases page
                    if let assets = json["assets"] as? [[String: Any]] {
                        for asset in assets {
                            if let name = asset["name"] as? String,
                               name.hasSuffix(".dmg"),
                               let url = asset["browser_download_url"] as? String {
                                downloadURL = url
                                break
                            }
                        }
                    }
                    if downloadURL == nil {
                        downloadURL = releasesPageURL.absoluteString
                    }
                }
            }
        } catch {
            // Silently fail — update check is non-critical
            print("UpdateChecker: \(error.localizedDescription)")
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
