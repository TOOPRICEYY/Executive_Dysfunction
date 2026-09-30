import Foundation

/// Device-local history, independent of the lifetime/cancellation of an allowance.
enum TemporaryAllowanceBackoff {
    static let daysRange = 1...365
    static let maximumWords = 38_400 // Same upper bound as the legacy session policy.
    static let defaultsKey = "temporary-allowance.backoff.v1"

    struct History: Codable, Equatable {
        var startedAt: Date
        var grants: Int

        func count(at now: Date, resetDays: Int) -> Int {
            let end = startedAt.addingTimeInterval(Double(min(365, max(1, resetDays))) * 86_400)
            // A clock rollback must not create a free reset.
            return now < end ? min(TemporaryAllowanceBackoff.maximumWords, max(0, grants)) : 0
        }
    }

    static func wordCount(base: Int, history: History?, resetDays: Int, at now: Date, sessionWordCount: Int = 0) -> Int {
        let count = history?.count(at: now, resetDays: resetDays) ?? 0
        // Backoff adds cross-session friction; it must never replace a higher
        // requirement already imposed by the current contiguous session.
        return min(maximumWords, max(sessionWordCount, min(300, max(20, base)) * (count + 1)))
    }

    static func history(for id: UUID, defaults: UserDefaults) -> History? {
        load(defaults: defaults)[id]
    }

    static func recordGrant(for id: UUID, resetDays: Int, at now: Date, defaults: UserDefaults) {
        var histories = load(defaults: defaults)
        let existing = histories[id]
        let count = existing?.count(at: now, resetDays: resetDays) ?? 0
        histories[id] = History(startedAt: count > 0 ? existing!.startedAt : now, grants: count + 1)
        defaults.set(try? JSONEncoder().encode(histories), forKey: defaultsKey)
    }

    private static func load(defaults: UserDefaults) -> [UUID: History] {
        guard let data = defaults.data(forKey: defaultsKey),
              let values = try? JSONDecoder().decode([UUID: History].self, from: data) else { return [:] }
        return values
    }

    static func description(resetDays: Int?) -> String {
        guard let resetDays else { return "Each further pause in the same session doubles the passage." }
        return "Across pauses: 1×, 2×, 3×, 4×… Resets \(resetDays) day(s) after the first use. Extending an ongoing pause still uses session doubling if that requires more words. Counted per group on this device. Maximum 38,400 words."
    }
}
