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
    /// An unlock can never open later than this instant.
    ///
    /// Set for a Retreat's early-end process, where the delay is capped at the
    /// Retreat's own remaining time: three days of friction guarding a
    /// thirty-nine hour Retreat is a request that can never come due. It is
    /// derived state, never user-set, so it stays out of `loosens` — the
    /// app-wide configuration always leaves it nil.
    var unlockCeiling: Date? = nil

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
    /// Allows a typed passage to suspend this rule for one of the fixed,
    /// short-duration temporary-access choices.
    var allowsTimeExtensions = false
    /// Bounds an allowance session so exponential passages cannot grow forever.
    var maximumTimeExtensionHours = 3
    var temporaryAllowanceResetDays: Int? = nil
    var temporaryAccessPassageWordCount: Int? = nil
    /// The session maximum in minutes. Optional so a rule compiled before
    /// minutes existed still decodes against the hour field above.
    var maximumTemporaryAccessMinutes: Int? = nil

    var effectiveTemporaryAccessPassageWordCount: Int {
        min(300, max(20, temporaryAccessPassageWordCount ?? passageWordCount))
    }

    /// The session maximum every caller should use.
    var effectiveMaximumTemporaryAccessMinutes: Int {
        let resolved = maximumTemporaryAccessMinutes ?? (maximumTimeExtensionHours * 60)
        return min(TimeAllowancePolicy.maximumMinutesRange.upperBound,
                   max(0, resolved))
    }

    /// Sets the session maximum, keeping the legacy hour field floored in step
    /// so an older reader never grants more than intended.
    mutating func setMaximumTemporaryAccess(minutes: Int) {
        let clamped = min(TimeAllowancePolicy.maximumMinutesRange.upperBound,
                          max(TimeAllowancePolicy.maximumMinutesRange.lowerBound, minutes))
        maximumTimeExtensionHours = clamped / 60
        // See CloudRuleLockdownPreference: a whole-hour value stays in the
        // legacy field so an unchanged policy is not rewritten.
        guard clamped % 60 != 0 || maximumTemporaryAccessMinutes != nil else { return }
        maximumTemporaryAccessMinutes = clamped
    }

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
        case temporaryAllowanceResetDays
        case temporaryAccessPassageWordCount
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
        temporaryAllowanceResetDays = try values.decodeIfPresent(Int.self, forKey: .temporaryAllowanceResetDays).map { min(365, max(1, $0)) }
        temporaryAccessPassageWordCount = try values.decodeIfPresent(Int.self, forKey: .temporaryAccessPassageWordCount).map { min(300, max(20, $0)) }
    }
}

enum TemporaryAccessDuration: Int, Codable, CaseIterable, Identifiable, Sendable {
    case oneMinute = 1
    case fiveMinutes = 5
    case tenMinutes = 10
    case thirtyMinutes = 30
    case sixtyMinutes = 60

    var id: Int { rawValue }
    var minutes: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue * 60) }

    var title: String {
        rawValue == 1 ? "1 minute" : "\(rawValue) minutes"
    }

    /// Apple's shield offers exactly three secondary submenu slots, so that
    /// path cannot grow with this list. It keeps the longer options, which are
    /// the ones worth reaching for from a shield; the finer grain is available
    /// in the app and on the block page, where there is room for every choice.
    static let shieldSubmenuOptions: [TemporaryAccessDuration] = [
        .tenMinutes, .thirtyMinutes, .sixtyMinutes
    ]
}

struct RuleTimeAllowance: Codable, Equatable {
    var ruleID: UUID
    var expiresAt: Date
    /// Legacy builds counted one-hour increments. Keep writing this field so a
    /// device that has not updated yet can still read a conservative grant
    /// count, while new builds use `grantCount` and `totalMinutesGranted`.
    var incrementsGranted: Int
    /// Cumulative access granted during this contiguous allowance session.
    /// It resets only after the allowance expires and is removed.
    var totalMinutesGranted: Int
    /// Number of passages accepted in this contiguous allowance session. This,
    /// rather than the chosen duration, drives exponential passage escalation.
    var grantCount: Int
    /// A usage-threshold shield was active when the allowance began or fired
    /// during it, and must be restored when the allowance expires.
    var restoreUsageShield: Bool

    init(
        ruleID: UUID,
        expiresAt: Date,
        incrementsGranted: Int,
        restoreUsageShield: Bool
    ) {
        let count = max(0, incrementsGranted)
        self.ruleID = ruleID
        self.expiresAt = expiresAt
        self.incrementsGranted = count
        totalMinutesGranted = count * 60
        grantCount = count
        self.restoreUsageShield = restoreUsageShield
    }

    init(
        ruleID: UUID,
        expiresAt: Date,
        totalMinutesGranted: Int,
        grantCount: Int,
        restoreUsageShield: Bool
    ) {
        let count = max(0, grantCount)
        self.ruleID = ruleID
        self.expiresAt = expiresAt
        incrementsGranted = count
        self.totalMinutesGranted = max(0, totalMinutesGranted)
        self.grantCount = count
        self.restoreUsageShield = restoreUsageShield
    }

    private enum CodingKeys: String, CodingKey {
        case ruleID, expiresAt, incrementsGranted
        case totalMinutesGranted, grantCount, restoreUsageShield
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ruleID = try values.decode(UUID.self, forKey: .ruleID)
        expiresAt = try values.decode(Date.self, forKey: .expiresAt)
        let legacyCount = max(0, try values.decodeIfPresent(Int.self, forKey: .incrementsGranted) ?? 0)
        grantCount = max(0, try values.decodeIfPresent(Int.self, forKey: .grantCount) ?? legacyCount)
        incrementsGranted = grantCount
        totalMinutesGranted = max(
            0,
            try values.decodeIfPresent(Int.self, forKey: .totalMinutesGranted)
                ?? (legacyCount * 60)
        )
        restoreUsageShield = try values.decodeIfPresent(Bool.self, forKey: .restoreUsageShield) ?? false
    }

    func isActive(at date: Date) -> Bool { date < expiresAt }

    /// DeviceActivity stores calendar boundaries at whole-second precision.
    /// Accept that boundary even when the persisted expiry has a fraction,
    /// while refusing a delayed callback belonging to an earlier grant.
    func isDueForMonitorEnd(at date: Date) -> Bool {
        date.timeIntervalSince1970 >= expiresAt.timeIntervalSince1970.rounded(.down)
    }

    func nextPassageWordCount(base: Int) -> Int {
        TimeAllowancePolicy.passageWordCount(
            base: base,
            incrementsAlreadyGranted: grantCount
        )
    }
}

enum TimeAllowancePolicy {
    static let hour: TimeInterval = 60 * 60
    static let maximumHoursRange = 1...8
    /// The session maximum is configured in minutes so a group can permit a
    /// genuinely short bypass. One minute is the floor; eight hours remains the
    /// ceiling.
    static let maximumMinutesRange = 1...480

    /// The values the session-maximum control steps through. A plain
    /// one-minute step would take hundreds of presses to cross eight hours, so
    /// the ladder is fine where it matters and coarse where it does not.
    static let maximumMinutesLadder = [
        1, 2, 3, 4, 5, 10, 15, 20, 30, 45,
        60, 90, 120, 180, 240, 300, 360, 420, 480
    ]

    /// The nearest ladder value at or below `minutes`, so a policy written with
    /// an arbitrary value still lands on a reachable rung.
    static func ladderIndex(forMinutes minutes: Int) -> Int {
        let clamped = min(maximumMinutesRange.upperBound, max(maximumMinutesRange.lowerBound, minutes))
        let index = maximumMinutesLadder.lastIndex { $0 <= clamped }
        return index ?? 0
    }

    static func describeMaximum(minutes: Int) -> String {
        let clamped = min(maximumMinutesRange.upperBound, max(maximumMinutesRange.lowerBound, minutes))
        if clamped < 60 { return clamped == 1 ? "1 minute" : "\(clamped) minutes" }
        let hours = clamped / 60
        let remainder = clamped % 60
        let hourText = hours == 1 ? "1 hour" : "\(hours) hours"
        return remainder == 0 ? hourText : "\(hourText) \(remainder) min"
    }

    static func canGrant(
        _ duration: TemporaryAccessDuration,
        afterMinutes alreadyGranted: Int,
        maximumMinutes: Int
    ) -> Bool {
        max(0, alreadyGranted) + duration.minutes <= max(0, maximumMinutes)
    }

    /// The first grant uses the base passage. Every consecutive grant doubles it.
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

        let requestedUnlockAt = process.startedAt
            .addingTimeInterval(TimeInterval(configuration.unlockDelayDays) * day)
        let unlocksAt = configuration.unlockCeiling.map { min(requestedUnlockAt, $0) } ?? requestedUnlockAt
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
        // Only the checkpoints that fit before the ceiling can be required, or
        // the process could never finish inside the window it guards.
        var requiredCheckpoints = configuration.unlockDelayDays
        if let ceiling = configuration.unlockCeiling {
            let fits = Int(ceiling.timeIntervalSince(process.startedAt) / day)
            requiredCheckpoints = min(requiredCheckpoints, max(0, fits))
        }
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
    static func compare(typed: String, passage: String, caseSensitive: Bool = false) -> [PassageDiffToken] {
        let actual = CommitmentPassage.normalizedWords(in: typed)
        let expected = CommitmentPassage.normalizedWords(in: passage)
        let actualComparison = actual.map { caseSensitive ? $0 : $0.lowercased() }
        let expectedComparison = expected.map { caseSensitive ? $0 : $0.lowercased() }

        // Backoff can produce tens of thousands of words. Keep comparison
        // memory bounded for those passages, while retaining nearby alignment.
        if actual.count > 0, expected.count > 1_000_000 / actual.count {
            var result: [PassageDiffToken] = []
            var i = 0, j = 0
            while i < actual.count, j < expected.count {
                if actualComparison[i] == expectedComparison[j] {
                    result.append(.init(text: actual[i], kind: .matched)); i += 1; j += 1
                } else if expectedComparison[(j + 1)..<min(expected.count, j + 33)].contains(actualComparison[i]),
                          !actualComparison[(i + 1)..<min(actual.count, i + 33)].contains(expectedComparison[j]) {
                    result.append(.init(text: expected[j], kind: .missing)); j += 1
                } else {
                    result.append(.init(text: actual[i], kind: .incorrect)); i += 1
                }
            }
            result.append(contentsOf: actual.dropFirst(i).map { .init(text: $0, kind: .incorrect) })
            result.append(contentsOf: expected.dropFirst(j).map { .init(text: $0, kind: .missing) })
            return result
        }

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
