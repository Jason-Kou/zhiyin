import Foundation

/// Tracks daily transcription usage for free-tier limits.
/// Disabled entirely when compiled with DISABLE_USAGE_LIMIT flag.
class UsageTracker: ObservableObject {
    static let shared = UsageTracker()

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
        return todayCount > Self.dailyFreeLimit
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
