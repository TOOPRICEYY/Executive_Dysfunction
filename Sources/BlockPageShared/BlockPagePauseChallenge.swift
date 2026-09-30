import Foundation

struct BlockPagePauseChallenge: Equatable, Sendable {
    var token: String
    var host: String
    var rule: BlockPageRuleDescriptor
    var policyRevision: UInt64
    var passage: String
    var issuedAt: Date
    var expiresAt: Date
}

enum BlockPagePauseChallengeError: Error, Equatable {
    case unavailable
    case expired
    case rateLimited
    case invalidHost
    case invalidRule
    case policyChanged
    case unsupportedDuration
    case passageMismatch
}

enum BlockPageConfirmationPassage {
    private static let sentences = [
        "I created this protection while thinking clearly about what I want for my future self.",
        "Right now I am asking for a short exception to a rule that I chose on purpose.",
        "If this urge is temporary, waiting will cost me nothing and protect what I planned.",
        "A deliberate pause gives the part of me that made this rule a meaningful vote.",
        "I do not have to act on every impulse that feels urgent in this moment.",
        "Temporary access is a conscious choice and the protection will return automatically.",
        "Typing these words is time to decide whether this exception serves what I actually want.",
        "I can leave the protection in place and lose nothing important by waiting today."
    ]

    private static let verificationWords = [
        "granite", "harbor", "lantern", "meadow", "compass", "willow", "ember",
        "summit", "quarry", "orchard", "beacon", "cedar", "atlas", "prairie",
        "anchor", "juniper", "canyon", "marble", "thicket", "drift"
    ]

    static func generate(wordCount: Int) -> String {
        let target = max(20, min(300, wordCount))
        let verification = ["Verification", "words:"]
            + (0..<6).compactMap { _ in verificationWords.randomElement() }
        let bodyTarget = max(0, target - verification.count)
        var pool = sentences.shuffled()
        var body: [String] = []
        while body.count < bodyTarget {
            if pool.isEmpty { pool = sentences.shuffled() }
            let words = pool.removeFirst().split(whereSeparator: \.isWhitespace).map(String.init)
            body.append(contentsOf: words.prefix(bodyTarget - body.count))
        }
        return (body + verification).joined(separator: " ")
    }

    static func matches(_ typed: String, passage: String) -> Bool {
        normalizedWords(in: typed).map { $0.lowercased() }
            == normalizedWords(in: passage).map { $0.lowercased() }
    }

    private static func normalizedWords(in text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }
}

/// In-memory authorization for a state-changing block-page request. Challenges
/// are host-, rule-, revision-, and fingerprint-bound, expire quickly, and are
/// consumed exactly once. Nothing reusable is written into the page or a cookie.
final class BlockPagePauseChallengeStore: @unchecked Sendable {
    typealias TokenGenerator = @Sendable () -> String
    typealias PassageGenerator = @Sendable (Int) -> String

    private struct Entry {
        var challenge: BlockPagePauseChallenge
        var failures: Int
    }

    private let lock = NSLock()
    private let lifetime: TimeInterval
    private let maximumActiveChallenges: Int
    private let maximumFailuresPerChallenge: Int
    private let maximumFailuresPerWindow: Int
    private let failureWindow: TimeInterval
    private let tokenGenerator: TokenGenerator
    private let passageGenerator: PassageGenerator
    private var entries: [String: Entry] = [:]
    private var failureDates: [Date] = []

    init(
        lifetime: TimeInterval = 5 * 60,
        maximumActiveChallenges: Int = 256,
        maximumFailuresPerChallenge: Int = 5,
        maximumFailuresPerWindow: Int = 40,
        failureWindow: TimeInterval = 60,
        tokenGenerator: @escaping TokenGenerator = {
            BlockPagePauseChallengeStore.secureToken()
        },
        passageGenerator: @escaping PassageGenerator = { wordCount in
            BlockPageConfirmationPassage.generate(wordCount: wordCount)
        }
    ) {
        self.lifetime = max(30, min(10 * 60, lifetime))
        self.maximumActiveChallenges = max(1, maximumActiveChallenges)
        self.maximumFailuresPerChallenge = max(1, maximumFailuresPerChallenge)
        self.maximumFailuresPerWindow = max(1, maximumFailuresPerWindow)
        self.failureWindow = max(10, failureWindow)
        self.tokenGenerator = tokenGenerator
        self.passageGenerator = passageGenerator
    }

    func issue(
        host rawHost: String,
        rule: BlockPageRuleDescriptor,
        policyRevision: UInt64,
        at now: Date = Date()
    ) -> Result<BlockPagePauseChallenge, BlockPagePauseChallengeError> {
        guard let host = BlockPageHostPolicy.normalizedDomain(rawHost),
              BlockPageRuleMatcher.eligibleRules(host: host, among: [rule]).count == 1 else {
            return .failure(.invalidRule)
        }
        let token = tokenGenerator()
        guard token.count >= 32, token.utf8.allSatisfy(Self.isSafeTokenByte) else {
            return .failure(.unavailable)
        }
        let challenge = BlockPagePauseChallenge(
            token: token,
            host: host,
            rule: rule,
            policyRevision: policyRevision,
            passage: passageGenerator(rule.passageWordCount),
            issuedAt: now,
            expiresAt: now.addingTimeInterval(lifetime)
        )

        lock.lock()
        defer { lock.unlock() }
        pruneLocked(at: now)
        if entries.count >= maximumActiveChallenges,
           let oldest = entries.min(by: { $0.value.challenge.issuedAt < $1.value.challenge.issuedAt })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[token] = Entry(challenge: challenge, failures: 0)
        return .success(challenge)
    }

    func redeem(
        token: String,
        host rawHost: String,
        ruleID: UUID,
        durationSeconds: Int,
        typedPassage: String,
        currentRule: BlockPageRuleDescriptor?,
        currentPolicyRevision: UInt64,
        at now: Date = Date()
    ) -> Result<BlockPageTemporaryPause, BlockPagePauseChallengeError> {
        lock.lock()
        defer { lock.unlock() }
        pruneFailuresLocked(at: now)
        guard failureDates.count < maximumFailuresPerWindow else {
            return .failure(.rateLimited)
        }
        guard var entry = entries[token] else {
            pruneLocked(at: now)
            recordFailureLocked(at: now)
            return .failure(.unavailable)
        }
        let challenge = entry.challenge
        guard challenge.expiresAt > now else {
            entries.removeValue(forKey: token)
            recordFailureLocked(at: now)
            return .failure(.expired)
        }
        guard let host = BlockPageHostPolicy.normalizedDomain(rawHost), host == challenge.host else {
            failLocked(token: token, entry: &entry, at: now)
            return .failure(.invalidHost)
        }
        guard challenge.rule.id == ruleID else {
            failLocked(token: token, entry: &entry, at: now)
            return .failure(.invalidRule)
        }
        guard let currentRule,
              currentPolicyRevision == challenge.policyRevision,
              currentRule.id == challenge.rule.id,
              currentRule.policyFingerprint == challenge.rule.policyFingerprint,
              BlockPageRuleMatcher.eligibleRules(host: host, among: [currentRule]).count == 1 else {
            entries.removeValue(forKey: token)
            recordFailureLocked(at: now)
            return .failure(.policyChanged)
        }
        guard BlockPagePauseDuration.allowedSeconds.contains(durationSeconds) else {
            failLocked(token: token, entry: &entry, at: now)
            return .failure(.unsupportedDuration)
        }
        guard BlockPageConfirmationPassage.matches(typedPassage, passage: challenge.passage) else {
            failLocked(token: token, entry: &entry, at: now)
            return .failure(.passageMismatch)
        }

        entries.removeValue(forKey: token)
        return .success(BlockPageTemporaryPause(
            ruleID: ruleID,
            policyRevision: currentPolicyRevision,
            policyFingerprint: currentRule.policyFingerprint,
            grantedAt: now,
            expiresAt: now.addingTimeInterval(Double(durationSeconds)),
            durationSeconds: durationSeconds,
            requestID: UUID()
        ))
    }

    private func failLocked(token: String, entry: inout Entry, at now: Date) {
        entry.failures += 1
        recordFailureLocked(at: now)
        if entry.failures >= maximumFailuresPerChallenge {
            entries.removeValue(forKey: token)
        } else {
            entries[token] = entry
        }
    }

    private func pruneLocked(at now: Date) {
        entries = entries.filter { $0.value.challenge.expiresAt > now }
    }

    private func pruneFailuresLocked(at now: Date) {
        let cutoff = now.addingTimeInterval(-failureWindow)
        failureDates.removeAll { $0 <= cutoff }
    }

    private func recordFailureLocked(at now: Date) {
        failureDates.append(now)
    }

    static func secureToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func isSafeTokenByte(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5a)
            || (byte >= 0x61 && byte <= 0x7a)
            || (byte >= 0x30 && byte <= 0x39)
            || byte == 0x2d
            || byte == 0x5f
    }
}
