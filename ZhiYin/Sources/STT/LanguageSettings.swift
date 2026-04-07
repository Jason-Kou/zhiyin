import Foundation

struct RecognitionLanguage: Identifiable {
    let code: String
    let flag: String
    let label: String
    var id: String { code }
}

class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()

    // MARK: - Language lists per engine

    /// FunASR pure ASR: zh, en, ja only
    static let funasr: [RecognitionLanguage] = [
        RecognitionLanguage(code: "auto", flag: "🌐", label: "Auto-detect"),
        RecognitionLanguage(code: "zh",   flag: "🇨🇳", label: "中文 Chinese"),
        RecognitionLanguage(code: "en",   flag: "🇺🇸", label: "English"),
        RecognitionLanguage(code: "ja",   flag: "🇯🇵", label: "日本語 Japanese"),
    ]

    /// FunASR MLT: 15 languages (current supported list)
    static let funasrMLT: [RecognitionLanguage] = [
        RecognitionLanguage(code: "auto", flag: "🌐", label: "Auto-detect"),
        RecognitionLanguage(code: "zh",   flag: "🇨🇳", label: "中文 Chinese"),
        RecognitionLanguage(code: "yue",  flag: "🇭🇰", label: "粵語 Cantonese"),
        RecognitionLanguage(code: "en",   flag: "🇺🇸", label: "English"),
        RecognitionLanguage(code: "ja",   flag: "🇯🇵", label: "日本語 Japanese"),
        RecognitionLanguage(code: "ko",   flag: "🇰🇷", label: "한국어 Korean"),
        RecognitionLanguage(code: "es",   flag: "🇪🇸", label: "Español Spanish"),
        RecognitionLanguage(code: "fr",   flag: "🇫🇷", label: "Français French"),
        RecognitionLanguage(code: "de",   flag: "🇩🇪", label: "Deutsch German"),
        RecognitionLanguage(code: "it",   flag: "🇮🇹", label: "Italiano Italian"),
        RecognitionLanguage(code: "pt",   flag: "🇧🇷", label: "Português Portuguese"),
        RecognitionLanguage(code: "ru",   flag: "🇷🇺", label: "Русский Russian"),
        RecognitionLanguage(code: "ar",   flag: "🇸🇦", label: "العربية Arabic"),
        RecognitionLanguage(code: "th",   flag: "🇹🇭", label: "ไทย Thai"),
        RecognitionLanguage(code: "vi",   flag: "🇻🇳", label: "Tiếng Việt Vietnamese"),
    ]

    /// Whisper Large V3 Turbo Q4: major languages from 100 supported
    static let whisper: [RecognitionLanguage] = [
        RecognitionLanguage(code: "auto", flag: "🌐", label: "Auto-detect"),
        RecognitionLanguage(code: "zh",   flag: "🇨🇳", label: "中文 Chinese"),
        RecognitionLanguage(code: "yue",  flag: "🇭🇰", label: "粵語 Cantonese"),
        RecognitionLanguage(code: "en",   flag: "🇺🇸", label: "English"),
        RecognitionLanguage(code: "ja",   flag: "🇯🇵", label: "日本語 Japanese"),
        RecognitionLanguage(code: "ko",   flag: "🇰🇷", label: "한국어 Korean"),
        RecognitionLanguage(code: "es",   flag: "🇪🇸", label: "Español Spanish"),
        RecognitionLanguage(code: "fr",   flag: "🇫🇷", label: "Français French"),
        RecognitionLanguage(code: "de",   flag: "🇩🇪", label: "Deutsch German"),
        RecognitionLanguage(code: "it",   flag: "🇮🇹", label: "Italiano Italian"),
        RecognitionLanguage(code: "pt",   flag: "🇧🇷", label: "Português Portuguese"),
        RecognitionLanguage(code: "nl",   flag: "🇳🇱", label: "Nederlands Dutch"),
        RecognitionLanguage(code: "ru",   flag: "🇷🇺", label: "Русский Russian"),
        RecognitionLanguage(code: "pl",   flag: "🇵🇱", label: "Polski Polish"),
        RecognitionLanguage(code: "tr",   flag: "🇹🇷", label: "Türkçe Turkish"),
        RecognitionLanguage(code: "uk",   flag: "🇺🇦", label: "Українська Ukrainian"),
        RecognitionLanguage(code: "ar",   flag: "🇸🇦", label: "العربية Arabic"),
        RecognitionLanguage(code: "hi",   flag: "🇮🇳", label: "हिन्दी Hindi"),
        RecognitionLanguage(code: "th",   flag: "🇹🇭", label: "ไทย Thai"),
        RecognitionLanguage(code: "vi",   flag: "🇻🇳", label: "Tiếng Việt Vietnamese"),
        RecognitionLanguage(code: "id",   flag: "🇮🇩", label: "Bahasa Indonesian"),
        RecognitionLanguage(code: "ms",   flag: "🇲🇾", label: "Bahasa Malay"),
        RecognitionLanguage(code: "tl",   flag: "🇵🇭", label: "Tagalog Filipino"),
        RecognitionLanguage(code: "sv",   flag: "🇸🇪", label: "Svenska Swedish"),
        RecognitionLanguage(code: "da",   flag: "🇩🇰", label: "Dansk Danish"),
        RecognitionLanguage(code: "fi",   flag: "🇫🇮", label: "Suomi Finnish"),
        RecognitionLanguage(code: "no",   flag: "🇳🇴", label: "Norsk Norwegian"),
        RecognitionLanguage(code: "he",   flag: "🇮🇱", label: "עברית Hebrew"),
        RecognitionLanguage(code: "el",   flag: "🇬🇷", label: "Ελληνικά Greek"),
        RecognitionLanguage(code: "cs",   flag: "🇨🇿", label: "Čeština Czech"),
        RecognitionLanguage(code: "ro",   flag: "🇷🇴", label: "Română Romanian"),
        RecognitionLanguage(code: "hu",   flag: "🇭🇺", label: "Magyar Hungarian"),
    ]

    /// Backward-compatible: returns MLT list (superset)
    static let available: [RecognitionLanguage] = funasrMLT

    /// Get languages for a given engine
    static func languages(for engine: String) -> [RecognitionLanguage] {
        switch engine {
        case "whisper": return whisper
        default: return funasrMLT
        }
    }

    @Published var selectedCode: String

    private let key = "recognitionLanguage"

    init() {
        let stored = UserDefaults.standard.string(forKey: key)
        selectedCode = stored ?? "auto"
        print("[LanguageSettings] init: stored=\(stored ?? "nil"), using=\(selectedCode)")
    }

    func save() {
        UserDefaults.standard.set(selectedCode, forKey: key)
        notifyServer()
    }

    /// Notification posted when server reports model_not_cached error
    static let modelNotCachedNotification = Notification.Name("ZhiYinModelNotCached")

    /// Tell the Python STT server to reload all settings.
    func notifyServer() {
        Task {
            guard let url = URL(string: "\(ServerConfig.baseURL)/reload-settings") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            if let (data, _) = try? await URLSession.shared.data(for: request),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = json["ok"] as? Bool, !ok,
               let error = json["error"] as? String, error == "model_not_cached" {
                await MainActor.run {
                    NotificationCenter.default.post(name: Self.modelNotCachedNotification, object: nil)
                }
            }
        }
    }
}
