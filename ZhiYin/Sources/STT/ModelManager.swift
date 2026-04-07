import Foundation

@MainActor
class ModelManager: ObservableObject {
    static let shared = ModelManager()

    struct ModelInfo: Identifiable {
        let engine: String
        let displayName: String
        var cached: Bool
        var sizeMB: Int
        var downloading: Bool
        var progress: Int
        var id: String { engine }
    }

    @Published var models: [ModelInfo] = []

    /// Called when a model download completes — engine name passed
    var onDownloadComplete: ((String) -> Void)?

    private var serverURL: String { ServerConfig.baseURL }
    private var pollTimer: Timer?

    // MARK: - Fetch model list

    func fetchModels() async {
        guard let url = URL(string: "\(serverURL)/model/list") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["models"] as? [[String: Any]] else { return }
            models = list.compactMap { item in
                guard let engine = item["engine"] as? String,
                      let displayName = item["display_name"] as? String else { return nil }
                return ModelInfo(
                    engine: engine,
                    displayName: displayName,
                    cached: item["cached"] as? Bool ?? false,
                    sizeMB: item["size_mb"] as? Int ?? 0,
                    downloading: item["downloading"] as? Bool ?? false,
                    progress: item["progress"] as? Int ?? 0
                )
            }
        } catch {
            print("ModelManager: fetchModels failed: \(error)")
        }
    }

    // MARK: - Download

    func downloadModel(_ engine: String) async {
        guard let url = URL(string: "\(serverURL)/model/download?engine=\(engine)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: request)

        // Mark as downloading locally for immediate UI update
        if let idx = models.firstIndex(where: { $0.engine == engine }) {
            models[idx].downloading = true
            models[idx].progress = 0
        }
        startPolling()
    }

    // MARK: - Delete

    func deleteModel(_ engine: String) async {
        guard let url = URL(string: "\(serverURL)/model/delete?engine=\(engine)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: request)
        await fetchModels()
    }

    // MARK: - Progress polling

    func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollProgress()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollProgress() async {
        guard let url = URL(string: "\(serverURL)/model/progress") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let downloads = json["downloads"] as? [String: [String: Any]] else { return }

            var anyDownloading = false
            for i in models.indices {
                let repoId = repoIdForEngine(models[i].engine)
                if let dl = downloads[repoId] {
                    let status = dl["status"] as? String ?? ""
                    models[i].progress = dl["progress"] as? Int ?? 0
                    models[i].downloading = (status == "downloading")
                    if status == "done" {
                        models[i].cached = true
                        models[i].downloading = false
                        models[i].progress = 100
                        onDownloadComplete?(models[i].engine)
                    }
                    if status == "downloading" {
                        anyDownloading = true
                    }
                }
            }

            if !anyDownloading {
                stopPolling()
                await fetchModels()  // refresh sizes
            }
        } catch {
            // Server not ready yet, ignore
        }
    }

    private func repoIdForEngine(_ engine: String) -> String {
        switch engine {
        case "funasr": return "mlx-community/Fun-ASR-MLT-Nano-2512-8bit"
        case "whisper": return "mlx-community/whisper-large-v3-turbo-q4"
        default: return ""
        }
    }
}
