import Foundation

/// Tracks daily transcription usage for free-tier limits.
/// Disabled entirely when compiled with DISABLE_USAGE_LIMIT flag.
class UsageTracker: ObservableObject {
    static let shared = UsageTracker()

    /// Master switch for the paid tier. ZhiYin is currently free and unlimited.
    ///
    /// Setting this to `true` restores the 50/day free limit and the $12 Pro
    /// upgrade. Nothing was deleted — flipping it back also requires:
    ///   - `MONETIZATION_ENABLED = True` in python/stt_server.py
    ///   - restoring the `.license` case in SettingsTab
    ///   - restoring the pricing copy in README.md / README.zh-CN.md
    static let monetizationEnabled = false

    static let dailyFreeLimit = 50

    @Published private(set) var todayCount: Int = 0

    private let countKey = "dailyTranscriptionCount"
    private let dateKey = "dailyTranscriptionDate"

    init() {
        resetIfNewDay()
    }

    /// Record a transcription. Returns true if within free limit.
    func record() -> Bool {
        #if DISABLE_USAGE_LIMIT
        return true
        #else
        guard Self.monetizationEnabled else { return true }
        resetIfNewDay()
        todayCount += 1
        UserDefaults.standard.set(todayCount, forKey: countKey)
        return todayCount <= Self.dailyFreeLimit
        #endif
    }

    /// Whether user has exceeded the daily free limit.
    var isOverLimit: Bool {
        #if DISABLE_USAGE_LIMIT
        return false
        #else
        return Self.monetizationEnabled && todayCount > Self.dailyFreeLimit
        #endif
    }

    var remaining: Int {
        max(0, Self.dailyFreeLimit - todayCount)
    }

    private func resetIfNewDay() {
        let today = Calendar.current.startOfDay(for: Date())
        let stored = UserDefaults.standard.object(forKey: dateKey) as? Date ?? .distantPast
        let storedDay = Calendar.current.startOfDay(for: stored)

        if today > storedDay {
            todayCount = 0
            UserDefaults.standard.set(0, forKey: countKey)
            UserDefaults.standard.set(today, forKey: dateKey)
        } else {
            todayCount = UserDefaults.standard.integer(forKey: countKey)
        }
    }
}
