import Foundation

/// A transient confirmation shown by the ordinary macOS disable button.
/// Emergency recovery remains a separate, immediate path because a broken
/// network filter must never require internet access or a long workflow to stop.
struct DesktopBlockingDisableChallenge: Equatable, Identifiable, Sendable {
    var id: UUID
    var policyRevision: UInt64
    var requiredPassage: String
    var issuedAt: Date
    var expiresAt: Date
}

enum DesktopBlockingDisableGate {
    enum Validation: String, Equatable, Sendable {
        case authorized
        case expired
        case notYetValid
        case policyChanged
        case passageMismatch
    }

    static let challengeLifetime: TimeInterval = 5 * 60
    static let defaultPassageWordCount = 40
    static let passageWordCountRange = 20...300

    /// Disabling the provider weakens every enabled rule, including rules whose
    /// next schedule has not begun. The strictest configured passage therefore
    /// wins; an entirely unlocked policy still requires a deliberate default.
    static func passageWordCount(for policy: DesktopEnforcementPolicy) -> Int {
        let configured = policy.rules
            .filter { $0.isEnabled && $0.lockdown.severity != "none" }
            .map(\.lockdown.passageWordCount)
            .max() ?? defaultPassageWordCount
        return min(passageWordCountRange.upperBound, max(passageWordCountRange.lowerBound, configured))
    }

    static func makeChallenge(
        for policy: DesktopEnforcementPolicy,
        at now: Date = Date(),
        id: UUID = UUID()
    ) -> DesktopBlockingDisableChallenge {
        DesktopBlockingDisableChallenge(
            id: id,
            policyRevision: policy.revision,
            requiredPassage: DesktopRemovalGate.passage(
                wordCount: passageWordCount(for: policy),
                seed: id
            ),
            issuedAt: now,
            expiresAt: now.addingTimeInterval(challengeLifetime)
        )
    }

    static func validate(
        typedPassage: String,
        challenge: DesktopBlockingDisableChallenge,
        currentPolicy: DesktopEnforcementPolicy,
        at now: Date = Date()
    ) -> Validation {
        guard now >= challenge.issuedAt else { return .notYetValid }
        guard now < challenge.expiresAt else { return .expired }
        guard currentPolicy.revision == challenge.policyRevision else { return .policyChanged }
        guard !challenge.requiredPassage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              DesktopRemovalGate.passageMatches(
            typedPassage,
            requiredPassage: challenge.requiredPassage
        ) else { return .passageMismatch }
        return .authorized
    }
}
