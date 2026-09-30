import Foundation

/// A deliberate, immediate escape hatch for removing the macOS Network
/// Extension. This is intentionally separate from ordinary rule-lock gates:
/// removal must remain possible when the filter itself is unhealthy, while an
/// eighty-word acknowledgement makes the destructive consequence explicit.
enum DesktopNetworkExtensionRemovalGate {
    enum Validation: String, Equatable, Sendable {
        case authorized
        case passageMismatch = "passage-mismatch"
    }

    /// Fixed instead of generated so the acknowledgement itself explains what
    /// will happen. Keep this at eighty words; focused tests protect both the
    /// attention cost and the safety information from accidental edits.
    static let requiredPassage = """
    I understand that removing the Holdfast network extension will stop filtering on this Mac. Blocked sites may become immediately available, active focus rules will no longer control network traffic, and the application cannot restore protection until the extension is installed and approved again. macOS may request an administrator password or approval, and removal may not finish until this Mac restarts. I am choosing to remove this protection now and accept that Internet access will continue without Holdfast protective web filtering.
    """

    static var requiredWordCount: Int {
        requiredPassage.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Literal comparison is deliberate. This action removes the enforcement
    /// component rather than pausing one rule, so the displayed passage must be
    /// entered exactly, including its capitalization and punctuation.
    static func validate(typedPassage: String) -> Validation {
        typedPassage == requiredPassage ? .authorized : .passageMismatch
    }
}
