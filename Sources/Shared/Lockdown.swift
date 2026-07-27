import Foundation

struct LockdownConfiguration: Codable, Equatable {
    var isEnabled = false
    /// Days between starting an unlock and being allowed to edit settings.
    var unlockDelayDays = 3
    /// Require re-typing a commitment passage each day of the wait, or the unlock cancels.
    var repeatConfirmations = false
    /// Words in the generated commitment passage.
    var passageWordCount = 40
    /// How long each scheduled checkpoint remains available before the request is cancelled.
    var confirmationWindowHours = 24
    /// How long settings remain editable after a successful unlock.
    var editWindowHours = 24

    static let delayRange = 0...365
    static let passageWordRange = 20...300
    static let confirmationWindowRange = 1...48
    static let editWindowRange = 1...72

    /// Whether switching to `other` weakens any protection. Loosening changes
    /// require an unlocked state; tightening is always allowed.
    func loosens(comparedTo other: LockdownConfiguration) -> Bool {
        (other.isEnabled && !isEnabled)
            || unlockDelayDays < other.unlockDelayDays
            || (other.repeatConfirmations && !repeatConfirmations)
            || passageWordCount < other.passageWordCount
            || confirmationWindowHours > other.confirmationWindowHours
            || editWindowHours > other.editWindowHours
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case unlockDelayDays
        case repeatConfirmations
        case passageWordCount
        case confirmationWindowHours
        case editWindowHours
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        unlockDelayDays = try values.decodeIfPresent(Int.self, forKey: .unlockDelayDays) ?? 3
        repeatConfirmations = try values.decodeIfPresent(Bool.self, forKey: .repeatConfirmations) ?? false
        passageWordCount = try values.decodeIfPresent(Int.self, forKey: .passageWordCount) ?? 40
        confirmationWindowHours = try values.decodeIfPresent(Int.self, forKey: .confirmationWindowHours) ?? 24
        editWindowHours = try values.decodeIfPresent(Int.self, forKey: .editWindowHours) ?? 24
    }
}

enum RuleLockdownSeverity: String, Codable, CaseIterable, Identifiable {
    case appDefault
    case none
    case passageOnly
    case delayed
    case repeatedConfirmations

    var id: Self { self }

    var title: String {
        switch self {
        case .appDefault: "App default"
        case .none: "No edit lock"
        case .passageOnly: "Passage only"
        case .delayed: "Delayed unlock"
        case .repeatedConfirmations: "Repeated confirmations"
        }
    }

    var explanation: String {
        switch self {
        case .appDefault: "Use the app-wide Settings Lockdown configuration."
        case .none: "This rule can be edited or removed immediately."
        case .passageOnly: "Require one passage, with no waiting period."
        case .delayed: "Require one passage followed by this rule's waiting period."
        case .repeatedConfirmations: "Require a passage at every 24-hour checkpoint or cancel the unlock."
        }
    }
}

struct RuleLockdownPolicy: Codable, Equatable {
    var severity: RuleLockdownSeverity = .appDefault
    var unlockDelayDays = 3
    var passageWordCount = 40
    var confirmationWindowHours = 24
    var editWindowHours = 24
    /// Allows a typed passage to suspend this rule in one-hour increments.
    var allowsTimeExtensions = false
    /// Bounds an allowance session so exponential passages cannot grow forever.
    var maximumTimeExtensionHours = 3

    func configuration(appDefault: LockdownConfiguration) -> LockdownConfiguration {
        guard severity != .appDefault else { return appDefault }

        var configuration = LockdownConfiguration()
        configuration.isEnabled = severity != .none
        configuration.unlockDelayDays = severity == .passageOnly ? 0 : unlockDelayDays
        configuration.repeatConfirmations = severity == .repeatedConfirmations
        configuration.passageWordCount = passageWordCount
        configuration.confirmationWindowHours = confirmationWindowHours
        configuration.editWindowHours = editWindowHours
        return configuration
    }
}

extension RuleLockdownPolicy {
    private enum CodingKeys: String, CodingKey {
        case severity, unlockDelayDays, passageWordCount
        case confirmationWindowHours, editWindowHours
        case allowsTimeExtensions, maximumTimeExtensionHours
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        severity = try values.decodeIfPresent(RuleLockdownSeverity.self, forKey: .severity) ?? .appDefault
        unlockDelayDays = try values.decodeIfPresent(Int.self, forKey: .unlockDelayDays) ?? 3
        passageWordCount = try values.decodeIfPresent(Int.self, forKey: .passageWordCount) ?? 40
        confirmationWindowHours = try values.decodeIfPresent(Int.self, forKey: .confirmationWindowHours) ?? 24
        editWindowHours = try values.decodeIfPresent(Int.self, forKey: .editWindowHours) ?? 24
        allowsTimeExtensions = try values.decodeIfPresent(Bool.self, forKey: .allowsTimeExtensions) ?? false
        maximumTimeExtensionHours = try values.decodeIfPresent(Int.self, forKey: .maximumTimeExtensionHours) ?? 3
    }
}

struct RuleTimeAllowance: Codable, Equatable {
    var ruleID: UUID
    var expiresAt: Date
    var incrementsGranted: Int
    /// A usage-threshold shield was active when the allowance began or fired
    /// during it, and must be restored when the allowance expires.
    var restoreUsageShield: Bool

    func isActive(at date: Date) -> Bool { date < expiresAt }

    func nextPassageWordCount(base: Int) -> Int {
        TimeAllowancePolicy.passageWordCount(
            base: base,
            incrementsAlreadyGranted: incrementsGranted
        )
    }
}

enum TimeAllowancePolicy {
    static let hour: TimeInterval = 60 * 60
    static let maximumHoursRange = 1...8

    /// The first hour uses the base passage. Every consecutive hour doubles it.
    static func passageWordCount(base: Int, incrementsAlreadyGranted: Int) -> Int {
        let multiplier = 1 << max(0, min(7, incrementsAlreadyGranted))
        return max(1, base) * multiplier
    }
}

struct UnlockProcess: Codable, Equatable {
    var startedAt: Date
    var confirmedAt: [Date]

    init(startedAt: Date) {
        self.startedAt = startedAt
        confirmedAt = [startedAt]
    }
}

enum UnlockPhase: Equatable {
    /// No unlock in progress; settings are locked while lockdown is enabled.
    case idle
    /// Waiting out the delay; no confirmation currently due.
    case waiting(unlocksAt: Date, nextConfirmationAt: Date?)
    /// Repeat-confirmations mode: a passage must be typed today to keep the unlock alive.
    case confirmationDue(unlocksAt: Date, deadline: Date, checkpoint: Int, total: Int)
    /// A confirmation window was missed; the process is void.
    case cancelled
    /// The wait is over; editing is open until the window closes.
    case unlocked(editWindowEndsAt: Date)
}

enum Lockdown {
    static let day: TimeInterval = 24 * 60 * 60

    static func phase(
        of process: UnlockProcess?,
        configuration: LockdownConfiguration,
        at now: Date,
        calendar _: Calendar = .current
    ) -> UnlockPhase {
        guard configuration.isEnabled, let process else { return .idle }

        let unlocksAt = process.startedAt
            .addingTimeInterval(TimeInterval(configuration.unlockDelayDays) * day)
        let editDuration = TimeInterval(configuration.editWindowHours) * 60 * 60

        guard configuration.repeatConfirmations else {
            guard now >= unlocksAt else {
                return .waiting(unlocksAt: unlocksAt, nextConfirmationAt: nil)
            }
            let windowEnd = unlocksAt.addingTimeInterval(editDuration)
            return now < windowEnd ? .unlocked(editWindowEndsAt: windowEnd) : .idle
        }

        // The initial passage is stored at index zero. Every completed 24-hour
        // checkpoint appends one additional timestamp, and no checkpoint can be
        // completed before its due time.
        let requiredCheckpoints = configuration.unlockDelayDays
        let completedCheckpoints = max(0, process.confirmedAt.count - 1)
        if completedCheckpoints >= requiredCheckpoints {
            let completedAt = process.confirmedAt.max() ?? unlocksAt
            let windowEnd = completedAt.addingTimeInterval(editDuration)
            return now < windowEnd ? .unlocked(editWindowEndsAt: windowEnd) : .idle
        }

        let checkpoint = completedCheckpoints + 1
        let dueAt = process.startedAt.addingTimeInterval(TimeInterval(checkpoint) * day)
        let deadline = dueAt.addingTimeInterval(
            TimeInterval(configuration.confirmationWindowHours) * 60 * 60
        )
        if now >= deadline { return .cancelled }
        if now < dueAt {
            return .waiting(unlocksAt: unlocksAt, nextConfirmationAt: dueAt)
        }
        return .confirmationDue(
            unlocksAt: unlocksAt,
            deadline: deadline,
            checkpoint: checkpoint,
            total: requiredCheckpoints
        )
    }
}

enum CommitmentPassage {
    private static let sentences = [
        "I created this lockdown while thinking clearly about what I want for my future self.",
        "Right now I am asking to remove a protection that I chose on purpose.",
        "If this urge is temporary, waiting will cost me nothing and protect everything I planned.",
        "A short delay is not a punishment, it is the space where better decisions happen.",
        "I do not have to act on every impulse that feels urgent in this moment.",
        "The version of me that set this up deserves a real vote in what happens next.",
        "Changing these settings should be a slow and deliberate act, never a reflex.",
        "I can always keep the protection in place and lose nothing at all today."
    ]

    private static let verificationWords = [
        "granite", "harbor", "lantern", "meadow", "compass", "willow", "ember",
        "summit", "quarry", "orchard", "beacon", "cedar", "atlas", "prairie",
        "anchor", "juniper", "canyon", "marble", "thicket", "drift"
    ]

    static func generate(wordCount: Int) -> String {
        let target = max(LockdownConfiguration.passageWordRange.lowerBound, wordCount)
        let verification = ["Verification", "words:"]
            + (0..<6).compactMap { _ in verificationWords.randomElement() }
        let bodyTarget = max(0, target - verification.count)
        var pool = sentences.shuffled()
        var body: [String] = []
        while body.count < bodyTarget {
            if pool.isEmpty { pool = sentences.shuffled() }
            let words = pool.removeFirst().split(separator: " ").map(String.init)
            body.append(contentsOf: words.prefix(bodyTarget - body.count))
        }
        return (body + verification).joined(separator: " ")
    }

    /// Case-insensitive, whitespace-collapsed comparison so line wrapping and
    /// capitalization differences do not fail an otherwise faithful entry.
    static func matches(_ typed: String, passage: String) -> Bool {
        normalizedWords(in: typed).map { $0.lowercased() }
            == normalizedWords(in: passage).map { $0.lowercased() }
    }

    static func normalizedWords(in text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }
}

enum PassageDiffKind: Equatable {
    case matched
    case incorrect
    case missing
}

struct PassageDiffToken: Equatable {
    var text: String
    var kind: PassageDiffKind
}

enum PassageDiff {
    /// Produces a word-level longest-common-subsequence diff. This keeps later
    /// correct words green even when an earlier word was omitted or inserted.
    static func compare(typed: String, passage: String) -> [PassageDiffToken] {
        let actual = CommitmentPassage.normalizedWords(in: typed)
        let expected = CommitmentPassage.normalizedWords(in: passage)
        let actualComparison = actual.map { $0.lowercased() }
        let expectedComparison = expected.map { $0.lowercased() }

        var lengths = Array(
            repeating: Array(repeating: 0, count: expected.count + 1),
            count: actual.count + 1
        )
        if !actual.isEmpty, !expected.isEmpty {
            for actualIndex in stride(from: actual.count - 1, through: 0, by: -1) {
                for expectedIndex in stride(from: expected.count - 1, through: 0, by: -1) {
                    if actualComparison[actualIndex] == expectedComparison[expectedIndex] {
                        lengths[actualIndex][expectedIndex] = 1 + lengths[actualIndex + 1][expectedIndex + 1]
                    } else {
                        lengths[actualIndex][expectedIndex] = max(
                            lengths[actualIndex + 1][expectedIndex],
                            lengths[actualIndex][expectedIndex + 1]
                        )
                    }
                }
            }
        }

        var result: [PassageDiffToken] = []
        var actualIndex = 0
        var expectedIndex = 0
        while actualIndex < actual.count, expectedIndex < expected.count {
            if actualComparison[actualIndex] == expectedComparison[expectedIndex] {
                result.append(.init(text: actual[actualIndex], kind: .matched))
                actualIndex += 1
                expectedIndex += 1
            } else if lengths[actualIndex + 1][expectedIndex] >= lengths[actualIndex][expectedIndex + 1] {
                result.append(.init(text: actual[actualIndex], kind: .incorrect))
                actualIndex += 1
            } else {
                result.append(.init(text: expected[expectedIndex], kind: .missing))
                expectedIndex += 1
            }
        }
        while actualIndex < actual.count {
            result.append(.init(text: actual[actualIndex], kind: .incorrect))
            actualIndex += 1
        }
        while expectedIndex < expected.count {
            result.append(.init(text: expected[expectedIndex], kind: .missing))
            expectedIndex += 1
        }
        return result
    }
}
