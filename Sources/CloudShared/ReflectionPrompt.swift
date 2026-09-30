import Foundation

/// A short, specific question answered before a temporary-access passage.
///
/// Typing a random passage costs effort but not thought; someone in a
/// hyperfocused impulse will simply transcribe it. Naming what the time is for
/// forces a moment of reflection, and the answer is saved with the bypass so
/// the pattern is visible later. It never changes passage length or duration.
enum ReflectionPrompt {
    static let minimumWords = 4
    static let maximumCharacters = 280

    static let prompts = [
        "What exactly will you do with this time, and when will you stop?",
        "What were you doing two minutes before you wanted this?",
        "What would you do instead if you waited ten minutes?",
        "What does the version of you who set this rule want right now?"
    ]

    /// Stable for one request so the question does not change mid-answer.
    static func prompt(for seed: UUID) -> String {
        let index = Int(seed.uuid.0) % prompts.count
        return prompts[index]
    }

    static func isSufficient(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).count >= minimumWords
    }

    /// Trimmed and bounded for storage; nil when the answer is too short.
    static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSufficient(trimmed) else { return nil }
        return String(trimmed.prefix(maximumCharacters))
    }
}
