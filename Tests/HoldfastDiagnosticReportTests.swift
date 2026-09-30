import XCTest
#if !DESKTOP_HOSTLESS_TESTS
@testable import Holdfast
#endif

final class HoldfastDiagnosticReportTests: XCTestCase {
    // MARK: - Redaction

    /// A report is meant to be sendable to someone else, so the default level
    /// must not carry the user's own words.
    func testStandardRedactionReplacesUserContent() {
        let redactor = HoldfastDiagnosticRedactor(.standard)
        let redacted = redactor.userContent("Evening Doomscroll")

        XCTAssertFalse(redacted.localizedCaseInsensitiveContains("doomscroll"))
        XCTAssertTrue(redacted.hasPrefix("<"))
        XCTAssertTrue(redacted.hasSuffix(">"))
    }

    func testFullRedactionKeepsUserContentVerbatim() {
        XCTAssertEqual(
            HoldfastDiagnosticRedactor(.full).userContent("Evening Doomscroll"),
            "Evening Doomscroll"
        )
    }

    /// Correlation across two devices is the whole reason digests are used
    /// rather than removal, so equal input must give equal output.
    func testDigestsAreStableAndCaseInsensitive() {
        let redactor = HoldfastDiagnosticRedactor(.standard)

        XCTAssertEqual(redactor.userContent("news.example"), redactor.userContent("News.Example"))
        XCTAssertNotEqual(redactor.userContent("news.example"), redactor.userContent("other.example"))
    }

    func testEmptyUserContentIsMarkedRatherThanDigested() {
        XCTAssertEqual(HoldfastDiagnosticRedactor(.standard).userContent("   "), "<empty>")
    }

    // MARK: - Formatting

    /// 1440 is the portable end-of-day sentinel. Showing it as 00:00 would hide
    /// the difference between "ends at midnight" and "starts at midnight".
    func testEndOfDaySentinelRendersAsTwentyFourHundred() {
        XCTAssertEqual(HoldfastDiagnosticReport.formatMinutes(1_440), "24:00")
        XCTAssertEqual(HoldfastDiagnosticReport.formatMinutes(0), "00:00")
        XCTAssertEqual(HoldfastDiagnosticReport.formatMinutes(9 * 60 + 30), "09:30")
    }

    func testWeekdayFormattingCollapsesAFullWeek() {
        XCTAssertEqual(HoldfastDiagnosticReport.formatWeekdays([1, 2, 3, 4, 5, 6, 7]), "daily")
        XCTAssertEqual(HoldfastDiagnosticReport.formatWeekdays([2, 4]), "Mon Wed")
        XCTAssertEqual(HoldfastDiagnosticReport.formatWeekdays([]), "none")
    }

    // MARK: - Round trip and rendering

    func testReportSurvivesAJSONRoundTrip() throws {
        let report = HoldfastDiagnosticReport(
            platform: "ios",
            redaction: .standard,
            warnings: [HoldfastDiagnosticWarning(
                code: "enforcement.shield-without-monitor",
                severity: .critical,
                message: "A block cannot release.",
                hint: "Check the monitor budget."
            )],
            sections: [HoldfastDiagnosticSection(
                title: "Enforcement",
                rows: [HoldfastDiagnosticRow("blocks active now", 2)],
                tables: [HoldfastDiagnosticTable(
                    title: "Time block enforcement",
                    columns: ["window", "monitor"],
                    rows: [["abc12345", "NO"]]
                )]
            )]
        )

        let decoded = try HoldfastDiagnosticReport.decode(report.jsonData())

        XCTAssertEqual(decoded.platform, "ios")
        XCTAssertEqual(decoded.warnings.first?.code, "enforcement.shield-without-monitor")
        XCTAssertEqual(decoded.sections.first?.tables.first?.rows.first, ["abc12345", "NO"])
    }

    /// The text rendering is what a person actually reads, so the findings and
    /// the table contents both have to survive into it.
    func testRenderedTextCarriesFindingsAndTables() {
        let report = HoldfastDiagnosticReport(
            platform: "macos",
            redaction: .standard,
            warnings: [HoldfastDiagnosticWarning(
                code: "filter.revision-behind",
                severity: .critical,
                message: "The filter is behind.",
                hint: "Republish."
            )],
            sections: [HoldfastDiagnosticSection(
                title: "Enforcement",
                rows: [HoldfastDiagnosticRow("published revision", "44")],
                tables: [HoldfastDiagnosticTable(
                    title: "Rules",
                    columns: ["id", "name"],
                    rows: [["abc12345", "<9f2a1c04>"]]
                )]
            )]
        )

        let text = report.renderedText()

        XCTAssertTrue(text.contains("[CRITICAL] filter.revision-behind"))
        XCTAssertTrue(text.contains("The filter is behind."))
        XCTAssertTrue(text.contains("→ Republish."))
        XCTAssertTrue(text.contains("published revision"))
        XCTAssertTrue(text.contains("abc12345"))
    }

    func testRenderedTextStatesWhenNothingIsWrong() {
        let report = HoldfastDiagnosticReport(platform: "ios", redaction: .full)

        XCTAssertTrue(report.renderedText().contains("No inconsistencies detected."))
    }

    func testEmptyTablesRenderTheirOwnExplanation() {
        let report = HoldfastDiagnosticReport(
            platform: "ios",
            redaction: .standard,
            sections: [HoldfastDiagnosticSection(
                title: "Monitors",
                tables: [HoldfastDiagnosticTable(
                    title: "Registered monitors",
                    columns: ["activity"],
                    emptyMessage: "No monitors are registered."
                )]
            )]
        )

        XCTAssertTrue(report.renderedText().contains("No monitors are registered."))
    }

    func testSuggestedFileNameIdentifiesPlatformAndTime() {
        let report = HoldfastDiagnosticReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            platform: "macos",
            redaction: .standard
        )

        XCTAssertTrue(report.suggestedFileName.hasPrefix("holdfast-diagnostics-macos-"))
        XCTAssertFalse(report.suggestedFileName.contains(" "))
    }

    /// An unset timestamp formats as a year-one date with a pre-standard-time
    /// zone offset, which reads as corrupted data rather than as "never set".
    func testUnsetTimestampsReadAsNever() {
        XCTAssertEqual(HoldfastDiagnosticReport.format(.distantPast), "never")
        XCTAssertNotEqual(HoldfastDiagnosticReport.format(Date(timeIntervalSince1970: 1_700_000_000)), "never")
    }

    func testCriticalWarningsAreSeparableFromTheRest() {
        let report = HoldfastDiagnosticReport(
            platform: "ios",
            redaction: .standard,
            warnings: [
                HoldfastDiagnosticWarning(code: "a", severity: .note, message: "note", hint: nil),
                HoldfastDiagnosticWarning(code: "b", severity: .critical, message: "critical", hint: nil),
                HoldfastDiagnosticWarning(code: "c", severity: .warning, message: "warning", hint: nil)
            ]
        )

        XCTAssertEqual(report.criticalWarnings.map(\.code), ["b"])
    }
}
