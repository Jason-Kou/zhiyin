import Foundation

struct DictionaryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var original: String
    var replacement: String
}

class PersonalDictionary: ObservableObject {
    static let shared = PersonalDictionary()

    @Published var entries: [DictionaryEntry] = []

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ZhiYin")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("dictionary.json")
        load()
    }

    func add(original: String, replacement: String) {
        entries.append(DictionaryEntry(original: original, replacement: replacement))
        save()
    }

    func remove(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        save()
    }

    func applyReplacements(_ text: String) -> String {
        var result = text
        for entry in entries {
            result = result.replacingOccurrences(of: entry.original, with: entry.replacement, options: .caseInsensitive)
        }
        return result
    }

    func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL)
        // Notify server to reload vocabulary prompt
        Task {
            guard let url = URL(string: "\(ServerConfig.baseURL)/reload-settings") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([DictionaryEntry].self, from: data) else { return }
        entries = decoded
    }

    func exportURL() -> URL {
        // Export without IDs — simpler for users to edit
        struct ExportEntry: Codable {
            let original: String
            let replacement: String
        }
        let exportEntries = entries.map { ExportEntry(original: $0.original, replacement: $0.replacement) }
        if let data = try? JSONEncoder().encode(exportEntries) {
            let exportURL = fileURL.deletingLastPathComponent().appendingPathComponent("dictionary_export.json")
            try? data.write(to: exportURL)
            return exportURL
        }
        return fileURL
    }

    func importFrom(url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        // Try decoding with IDs first, then without
        if let decoded = try? JSONDecoder().decode([DictionaryEntry].self, from: data) {
            entries = decoded
        } else {
            // Support simplified format: [{"original": "...", "replacement": "..."}]
            struct SimpleEntry: Codable {
                let original: String
                let replacement: String
            }
            guard let simple = try? JSONDecoder().decode([SimpleEntry].self, from: data) else { return }
            entries = simple.map { DictionaryEntry(original: $0.original, replacement: $0.replacement) }
        }
        save()
    }
}
