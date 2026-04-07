import Foundation
import AppKit

enum PostProcessing: String, Codable, CaseIterable, Identifiable {
    case none, formal, casual, code
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: return "None"
        case .formal: return "Writing (Formal)"
        case .casual: return "Chat (Casual)"
        case .code: return "Code"
        }
    }
}

struct ModeSettings: Codable, Equatable {
    var language: String = "chinese"
    var postProcessing: PostProcessing = .none
    var customPrompt: String = ""
}

struct AppMode: Codable, Identifiable, Equatable {
    var id = UUID()
    var bundleId: String
    var appName: String
    var modeName: String
    var settings: ModeSettings
}

class PowerModeManager: ObservableObject {
    static let shared = PowerModeManager()

    @Published var appModes: [AppMode] = []

    private let fileURL: URL

    static let presets: [(String, PostProcessing)] = [
        ("Writing", .formal),
        ("Chat", .casual),
        ("Code", .code),
    ]

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ZhiYin")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("power_modes.json")
        load()
    }

    func modeForCurrentApp() -> AppMode? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleId = frontApp.bundleIdentifier else { return nil }
        return appModes.first { $0.bundleId == bundleId }
    }

    func add(_ mode: AppMode) {
        appModes.append(mode)
        save()
    }

    func remove(at offsets: IndexSet) {
        appModes.remove(atOffsets: offsets)
        save()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(appModes) else { return }
        try? data.write(to: fileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([AppMode].self, from: data) else { return }
        appModes = decoded
    }
}
