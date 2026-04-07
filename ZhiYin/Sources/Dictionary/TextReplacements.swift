import Foundation

struct TextReplacement: Codable, Identifiable, Equatable {
    var id = UUID()
    var trigger: String
    var replacement: String
    var isRegex: Bool
}

class TextReplacementManager: ObservableObject {
    static let shared = TextReplacementManager()

    @Published var replacements: [TextReplacement] = []

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ZhiYin")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("replacements.json")
        load()
        if replacements.isEmpty {
            loadDefaults()
        }
    }

    private func loadDefaults() {
        replacements = [
            TextReplacement(trigger: "换行", replacement: "\n", isRegex: false),
            TextReplacement(trigger: "新段落", replacement: "\n\n", isRegex: false),
            TextReplacement(trigger: "句号", replacement: "\u{3002}", isRegex: false),
            TextReplacement(trigger: "逗号", replacement: "\u{FF0C}", isRegex: false),
            TextReplacement(trigger: "问号", replacement: "\u{FF1F}", isRegex: false),
            TextReplacement(trigger: "感叹号", replacement: "\u{FF01}", isRegex: false),
        ]
        save()
    }

    func add(trigger: String, replacement: String, isRegex: Bool = false) {
        replacements.append(TextReplacement(trigger: trigger, replacement: replacement, isRegex: isRegex))
        save()
    }

    func remove(at offsets: IndexSet) {
        replacements.remove(atOffsets: offsets)
        save()
    }

    func applyReplacements(_ text: String) -> String {
        var result = text
        for entry in replacements {
            if entry.isRegex {
                if let regex = try? NSRegularExpression(pattern: entry.trigger) {
                    let range = NSRange(result.startIndex..., in: result)
                    result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: entry.replacement)
                }
            } else {
                result = result.replacingOccurrences(of: entry.trigger, with: entry.replacement)
            }
        }
        return result
    }

    func save() {
        guard let data = try? JSONEncoder().encode(replacements) else { return }
        try? data.write(to: fileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([TextReplacement].self, from: data) else { return }
        replacements = decoded
    }

    func resetToDefaults() {
        replacements = []
        loadDefaults()
    }
}
