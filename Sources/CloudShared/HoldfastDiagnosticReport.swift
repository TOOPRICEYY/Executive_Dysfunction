import CryptoKit
import Foundation

/// How much of the user's own content a report is allowed to carry.
///
/// A diagnostic report is meant to be sendable to someone else, so names and
/// domains are replaced by stable digests unless the person exporting it asks
/// for them. The digests still support the questions a trace has to answer --
/// whether two devices are looking at the same rule, whether a domain survived
/// a round trip -- without disclosing what the content is.
enum HoldfastDiagnosticRedaction: String, Codable, Equatable, Sendable {
    /// Names and domains are digested. Counts, identifiers, states and times
    /// are always present at both levels.
    case standard
    /// Names and domains appear verbatim.
    case full

    var summary: String {
        switch self {
        case .standard: "names and domains are digested"
        case .full: "names and domains are included verbatim"
        }
    }
}

struct HoldfastDiagnosticRedactor: Sendable {
    let level: HoldfastDiagnosticRedaction

    init(_ level: HoldfastDiagnosticRedaction) {
        self.level = level
    }

    /// User-authored text: a rule name, a domain, an application identifier.
    func userContent(_ value: String) -> String {
        guard level == .standard else { return value }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "<empty>" }
        return "<\(Self.digest(trimmed))>"
    }

    /// Identifiers are never secret, but a full UUID in every row makes a report
    /// unreadable. The leading octet group is enough to correlate rows within
    /// one report and across a pair of devices.
    func identifier(_ value: UUID) -> String {
        String(value.uuidString.prefix(8))
    }

    /// A stable short digest. Equal input gives equal output on every device and
    /// every launch, which is what makes cross-device correlation possible.
    static func digest(_ value: String) -> String {
        let hash = Insecure.MD5.hash(data: Data(value.lowercased().utf8))
        return hash.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }
}

/// A problem the report diagnosed about itself.
///
/// This is the part that localizes a bug. A reader should not have to know that
/// a shield without a monitor never releases; the report says so.
struct HoldfastDiagnosticWarning: Codable, Equatable, Sendable, Identifiable {
    enum Severity: String, Codable, Equatable, Sendable, Comparable {
        case critical
        case warning
        case note

        var rank: Int {
            switch self {
            case .critical: 0
            case .warning: 1
            case .note: 2
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
    }

    var id: String { code }
    /// A stable slug so the same condition is greppable across reports.
    var code: String
    var severity: Severity
    var message: String
    /// What to do, or where to look next.
    var hint: String?
}

struct HoldfastDiagnosticRow: Codable, Equatable, Sendable {
    var key: String
    var value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    init(_ key: String, _ value: Int) {
        self.init(key, String(value))
    }

    init(_ key: String, _ value: Bool) {
        self.init(key, value ? "yes" : "no")
    }

    init(_ key: String, _ value: Date?) {
        self.init(key, value.map(HoldfastDiagnosticReport.format) ?? "—")
    }
}

/// A repeating structure -- one row per time block, per rule, per trace event.
struct HoldfastDiagnosticTable: Codable, Equatable, Sendable {
    var title: String
    var columns: [String]
    var rows: [[String]]
    /// Shown in place of the table when it has no rows.
    var emptyMessage: String

    init(title: String, columns: [String], rows: [[String]] = [], emptyMessage: String = "none") {
        self.title = title
        self.columns = columns
        self.rows = rows
        self.emptyMessage = emptyMessage
    }
}

struct HoldfastDiagnosticSection: Codable, Equatable, Sendable {
    var title: String
    /// Why this section exists and how to read it.
    var explanation: String?
    var rows: [HoldfastDiagnosticRow]
    var tables: [HoldfastDiagnosticTable]

    init(
        title: String,
        explanation: String? = nil,
        rows: [HoldfastDiagnosticRow] = [],
        tables: [HoldfastDiagnosticTable] = []
    ) {
        self.title = title
        self.explanation = explanation
        self.rows = rows
        self.tables = tables
    }
}

/// One device's full interpretable state at a moment in time.
///
/// The schema is deliberately shared by iOS and macOS. The two platforms
/// enforce through completely different machinery, but a reader comparing an
/// iPhone report against a Mac report should not have to learn two formats, and
/// the object graph they disagree about is the same one.
struct HoldfastDiagnosticReport: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion = Self.schemaVersion
    var generatedAt: Date
    /// "ios" or "macos".
    var platform: String
    var redaction: HoldfastDiagnosticRedaction
    var warnings: [HoldfastDiagnosticWarning]
    var sections: [HoldfastDiagnosticSection]

    init(
        generatedAt: Date = Date(),
        platform: String,
        redaction: HoldfastDiagnosticRedaction,
        warnings: [HoldfastDiagnosticWarning] = [],
        sections: [HoldfastDiagnosticSection] = []
    ) {
        self.generatedAt = generatedAt
        self.platform = platform
        self.redaction = redaction
        self.warnings = warnings
        self.sections = sections
    }

    var criticalWarnings: [HoldfastDiagnosticWarning] {
        warnings.filter { $0.severity == .critical }
    }

    /// Suggested file name. Second resolution keeps successive exports distinct
    /// without making the name unreadable.
    var suggestedFileName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "holdfast-diagnostics-\(platform)-\(formatter.string(from: generatedAt))"
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: data)
    }

    static func format(_ date: Date) -> String {
        // An unset timestamp is `distantPast`, which formats as a year-one date
        // with a pre-standard-time zone offset. In a report whose whole purpose
        // is legibility that reads as corruption rather than as "never set".
        guard date > Date(timeIntervalSince1970: 0) else { return "never" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    /// Minutes-from-midnight as the schedule stores them. 1440 is the portable
    /// end-of-day boundary and is deliberately shown as such rather than
    /// wrapping to 00:00, because that distinction has caused real bugs.
    static func formatMinutes(_ minutes: Int) -> String {
        guard minutes != 1_440 else { return "24:00" }
        let normalized = max(0, min(1_439, minutes))
        return String(format: "%02d:%02d", normalized / 60, normalized % 60)
    }

    static func formatWeekdays(_ weekdays: Set<Int>) -> String {
        let names = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]
        guard !weekdays.isEmpty else { return "none" }
        if weekdays.count == 7 { return "daily" }
        return weekdays.sorted().compactMap { names[$0] }.joined(separator: " ")
    }

    /// One independently renderable piece of the report.
    ///
    /// A view that lays the report out block by block stays responsive; one very
    /// large text run does not, and it makes accessibility traversal crawl.
    struct RenderedBlock: Identifiable, Equatable, Sendable {
        var id: Int
        var title: String
        var body: String
    }

    /// A human-readable rendering of the same content the JSON carries. A report
    /// is useless if reading it requires tooling, so the export ships both.
    func renderedText() -> String {
        renderedBlocks()
            .map { $0.body }
            .joined(separator: "\n\n")
    }

    func renderedBlocks() -> [RenderedBlock] {
        var blocks: [RenderedBlock] = []

        blocks.append(RenderedBlock(
            id: 0,
            title: "HOLDFAST DIAGNOSTIC REPORT",
            body: [
                "HOLDFAST DIAGNOSTIC REPORT",
                String(repeating: "=", count: 78),
                "generated   \(Self.format(generatedAt))",
                "platform    \(platform)",
                "schema      \(schemaVersion)",
                "redaction   \(redaction.rawValue) — \(redaction.summary)"
            ].joined(separator: "\n")
        ))

        var findingLines = ["FINDINGS", String(repeating: "-", count: 78)]
        if warnings.isEmpty {
            findingLines.append("No inconsistencies detected.")
        } else {
            for warning in warnings.sorted(by: { $0.severity < $1.severity }) {
                findingLines.append("[\(warning.severity.rawValue.uppercased())] \(warning.code)")
                findingLines.append("  \(warning.message)")
                if let hint = warning.hint {
                    findingLines.append("  → \(hint)")
                }
            }
        }
        blocks.append(RenderedBlock(id: 1, title: "FINDINGS", body: findingLines.joined(separator: "\n")))

        for (offset, section) in sections.enumerated() {
            var lines = [section.title.uppercased(), String(repeating: "-", count: 78)]
            if let explanation = section.explanation {
                lines.append(explanation)
                lines.append("")
            }
            let keyWidth = section.rows.map(\.key.count).max() ?? 0
            for row in section.rows {
                lines.append("\(row.key.padding(toLength: max(keyWidth, 1), withPad: " ", startingAt: 0))  \(row.value)")
            }
            for table in section.tables {
                lines.append("")
                lines.append("· \(table.title)")
                lines.append(contentsOf: Self.renderTable(table).map { "  \($0)" })
            }
            blocks.append(RenderedBlock(
                id: offset + 2,
                title: section.title,
                body: lines.joined(separator: "\n")
            ))
        }

        return blocks
    }

    private static func renderTable(_ table: HoldfastDiagnosticTable) -> [String] {
        guard !table.rows.isEmpty else { return [table.emptyMessage] }
        var widths = table.columns.map(\.count)
        for row in table.rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }

        func line(_ cells: [String]) -> String {
            cells.enumerated()
                .map { index, cell in
                    index < widths.count
                        ? cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
                        : cell
                }
                .joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces)
        }

        var lines = [line(table.columns)]
        lines.append(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
        lines.append(contentsOf: table.rows.map(line))
        return lines
    }
}
