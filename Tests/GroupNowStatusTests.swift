import XCTest
#if !DESKTOP_HOSTLESS_TESTS
@testable import Holdfast
#endif

final class GroupNowStatusTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Detroit")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        // September 2026: the 28th is a Monday.
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private let weekdays = CloudTimeWindow(weekdays: [2, 3, 4, 5, 6], startMinutes: 9 * 60, endMinutes: 17 * 60)
    private let overnight = CloudTimeWindow(weekdays: [1, 2, 3, 4, 5, 6, 7], startMinutes: 21 * 60, endMinutes: 7 * 60)

    func testBlockingNowUntilWindowEnd() {
        let state = GroupNowStatus.evaluate(isEnabled: true, windows: [weekdays], now: date(29, 10), calendar: calendar)
        XCTAssertEqual(state, .blocking(until: date(29, 17)))
        XCTAssertTrue(state.isBlocking)
    }

    func testOvernightWindowThatStartedYesterday() {
        let state = GroupNowStatus.evaluate(isEnabled: true, windows: [overnight], now: date(29, 6), calendar: calendar)
        XCTAssertEqual(state, .blocking(until: date(29, 7)))
    }

    func testUpcomingAcrossTheWeekend() {
        // Saturday 3 Oct, 12:00: next weekday window is Monday 5 Oct 09:00.
        let state = GroupNowStatus.evaluate(isEnabled: true, windows: [weekdays], now: date(26, 12).addingTimeInterval(7 * 86_400), calendar: calendar)
        XCTAssertEqual(state, .upcoming(at: calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9))!))
    }

    func testAlwaysOnHasNoEnd() {
        let always = CloudTimeWindow(weekdays: [1, 2, 3, 4, 5, 6, 7], startMinutes: 0, endMinutes: 1_440)
        XCTAssertEqual(GroupNowStatus.evaluate(isEnabled: true, windows: [always], now: date(29, 12), calendar: calendar),
                       .blocking(until: nil))
    }

    func testLockdownPauseAndOffTakePrecedence() {
        let now = date(29, 10)
        XCTAssertEqual(GroupNowStatus.evaluate(isEnabled: false, windows: [weekdays], now: now,
                                               lockdownUntil: date(29, 20), calendar: calendar), .lockdown(until: date(29, 20)))
        XCTAssertEqual(GroupNowStatus.evaluate(isEnabled: true, windows: [weekdays], now: now,
                                               allowanceUntil: date(29, 10, 30), calendar: calendar), .paused(until: date(29, 10, 30)))
        XCTAssertEqual(GroupNowStatus.evaluate(isEnabled: false, windows: [weekdays], now: now, calendar: calendar), .off)
        XCTAssertEqual(GroupNowStatus.evaluate(isEnabled: true, windows: [], now: now, calendar: calendar), .idle)
    }

    func testIntervalsAreMergedAndClipped() {
        let a = CloudTimeWindow(weekdays: [3], startMinutes: 9 * 60, endMinutes: 12 * 60)
        let b = CloudTimeWindow(weekdays: [3], startMinutes: 11 * 60, endMinutes: 14 * 60)
        let intervals = ScheduleTimeline.intervals(windows: [a, b], from: date(29, 10), to: date(29, 13), calendar: calendar)
        XCTAssertEqual(intervals, [BlockingInterval(start: date(29, 10), end: date(29, 13))])
    }

    func testSummaryCountsAndPicksTheSoonestChange() {
        let now = date(29, 10)
        let summary = DashboardNowSummary(groups: [
            .init(name: "Social", state: .blocking(until: date(29, 17))),
            .init(name: "Gmail", state: .blocking(until: date(29, 12))),
            .init(name: "Evenings", state: .upcoming(at: date(29, 21))),
            .init(name: "Games", state: .off)
        ])
        XCTAssertEqual(summary.blockingCount, 2)
        XCTAssertEqual(summary.nextChange, date(29, 12))
        XCTAssertEqual(summary.nextChangeDescription, "Gmail ends")
        XCTAssertEqual(summary.headline, "2 groups blocking now")
        XCTAssertTrue(summary.nextLine(now: now, calendar: calendar)?.hasPrefix("Next: Gmail ends at ") ?? false)
        XCTAssertEqual(DashboardNowSummary(groups: []).headline, "Nothing is blocked right now")
    }

    func testLaneLayoutClampsAndSortsInForceFirst() {
        let start = calendar.startOfDay(for: date(29, 12))
        XCTAssertEqual(ScheduleLanes.fraction(of: date(29, 12), dayStart: start, calendar: calendar), 0.5, accuracy: 0.001)
        XCTAssertEqual(ScheduleLanes.fraction(of: date(28, 12), dayStart: start, calendar: calendar), 0)
        let lanes = ScheduleLanes.sorted([
            .init(id: UUID(), name: "Off", intervals: [], state: .off),
            .init(id: UUID(), name: "Later", intervals: [], state: .upcoming(at: date(29, 21))),
            .init(id: UUID(), name: "Now", intervals: [], state: .blocking(until: date(29, 17)))
        ])
        XCTAssertEqual(lanes.map(\.name), ["Now", "Later", "Off"])
    }

    func testLanesForAnotherDayUseScheduleRetreatRunAndLockdowns() {
        var rule = CloudRulePreference(name: "Work")
        rule.isEnabled = true
        rule.windows = [weekdays]
        var retreat = CloudRulePreference(name: "Retreat")
        retreat.isEnabled = true
        retreat.windows = [CloudTimeWindow(weekdays: [1, 2, 3, 4, 5, 6, 7], startMinutes: 0, endMinutes: 1_440)]
        var disabled = CloudRulePreference(name: "Held")
        disabled.isEnabled = false
        disabled.windows = [weekdays]
        let entries = [
            BlockStatusCalendarRule(rule: rule),
            // The retreat runs Wednesday noon to Thursday noon.
            BlockStatusCalendarRule(rule: retreat, enforcementInterval: DateInterval(start: date(30, 12), end: date(30, 12).addingTimeInterval(86_400))),
            BlockStatusCalendarRule(rule: disabled, forcedIntervals: [DateInterval(start: date(30, 20), end: date(30, 22))])
        ]
        // Wednesday 30 September, viewed from Tuesday.
        let lanes = ScheduleLanes.lanes(for: entries, day: date(30, 0), now: date(29, 10), calendar: calendar)
        let byName = Dictionary(uniqueKeysWithValues: lanes.map { ($0.name, $0) })
        XCTAssertEqual(byName["Work"]?.intervals, [BlockingInterval(start: date(30, 9), end: date(30, 17))])
        XCTAssertEqual(byName["Retreat"]?.intervals, [BlockingInterval(start: date(30, 12), end: date(30, 0).addingTimeInterval(86_400))])
        XCTAssertEqual(byName["Held"]?.intervals, [BlockingInterval(start: date(30, 20), end: date(30, 22))])
        XCTAssertNil(byName["Work"]?.state, "Only today carries a live state")
        XCTAssertEqual(byName["Work"]?.blockedMinutes, 480)
        XCTAssertEqual(ScheduleLanes.duration(minutes: 480), "8h")
        XCTAssertEqual(ScheduleLanes.duration(minutes: 90), "1h 30m")
        XCTAssertEqual(ScheduleLanes.duration(minutes: 0), "Free")
    }
}

extension GroupNowStatusTests {
    private func subject(
        _ name: String,
        blocking: Bool,
        sites: [String],
        retreat: Bool = false,
        fortress: Bool = false
    ) -> GroupCoverage.Subject {
        GroupCoverage.Subject(
            id: UUID(),
            name: name,
            isRetreatCopy: retreat,
            isBlockingNow: blocking,
            isAllowListFortress: fortress,
            targets: GroupCoverage.targets(
                domains: sites, websiteCategories: [], applicationIdentifiers: []
            )
        )
    }

    /// The case this came from: the Youtube group's own window had ended, but
    /// youtube.com was still unreachable because a Retreat's "Full break"
    /// listed it. The row said "Next block · tomorrow", which reads as an
    /// invitation.
    func testAGroupWhoseSitesAreHeldElsewhereIsToldSo() {
        let idle = subject("Youtube", blocking: false, sites: ["youtube.com"])
        let holder = subject("Full break", blocking: true, sites: ["youtube.com", "reddit.com"], retreat: true)

        let holders = GroupCoverage.holders(for: [idle, holder])

        XCTAssertEqual(holders[idle.id], GroupCoverage.Holder(name: "Full break (Retreat)", isComplete: true))
        XCTAssertNil(holders[holder.id], "A group that is blocking already says so itself")
    }

    func testPartialOverlapIsReportedAsPartial() {
        let idle = subject("Hyper intellectualizing", blocking: false, sites: ["reddit.com", "metr.com"])
        let holder = subject("Full break", blocking: true, sites: ["reddit.com"])

        XCTAssertEqual(
            GroupCoverage.holders(for: [idle, holder])[idle.id],
            GroupCoverage.Holder(name: "Full break", isComplete: false)
        )
    }

    /// Two holders between them can cover everything even though neither does
    /// alone, and the row should not claim to be only partly blocked.
    func testTwoHoldersTogetherCountAsCompleteCover() {
        let idle = subject("Feeds", blocking: false, sites: ["reddit.com", "x.com"])
        let first = subject("Aardvark", blocking: true, sites: ["reddit.com"])
        let second = subject("Zebra", blocking: true, sites: ["x.com"])

        let holder = GroupCoverage.holders(for: [idle, first, second])[idle.id]

        XCTAssertEqual(holder?.isComplete, true)
        XCTAssertNotNil(holder?.name)
    }

    /// An allow-list group blocks everything it does not name, so it holds
    /// every other group's sites while it runs.
    func testAnAllowListFortressCoversEverything() {
        let idle = subject("Feeds", blocking: false, sites: ["reddit.com", "metr.com"])
        let fortress = subject("Deep work", blocking: true, sites: ["docs.example"], fortress: true)

        XCTAssertEqual(
            GroupCoverage.holders(for: [idle, fortress])[idle.id],
            GroupCoverage.Holder(name: "Deep work", isComplete: true)
        )
    }

    /// www. is a spelling of the same site, not a different target.
    func testWWWPrefixDoesNotHideAnOverlap() {
        let idle = subject("Twitter", blocking: false, sites: ["www.x.com"])
        let holder = subject("Full break", blocking: true, sites: ["x.com"])

        XCTAssertEqual(GroupCoverage.holders(for: [idle, holder])[idle.id]?.isComplete, true)
    }

    func testUnrelatedGroupsAreLeftAlone() {
        let idle = subject("Mail", blocking: false, sites: ["mail.google.com"])
        let holder = subject("Full break", blocking: true, sites: ["reddit.com"])

        XCTAssertNil(GroupCoverage.holders(for: [idle, holder])[idle.id])
    }

    /// Screen Time selections are opaque tokens, so a group with no portable
    /// targets cannot be matched and keeps its own schedule's wording.
    func testAGroupWithNoPortableTargetsIsNeverCovered() {
        let idle = subject("Apps only", blocking: false, sites: [])
        let holder = subject("Full break", blocking: true, sites: ["reddit.com"])

        XCTAssertNil(GroupCoverage.holders(for: [idle, holder])[idle.id])
    }

    func testHeadlineLeadsWithTheGroupActuallyBlocking() {
        let state = GroupNowStatus.evaluate(
            isEnabled: true, windows: [weekdays], now: date(28, 18), calendar: calendar
        )
        let sentence = GroupNowStatus.headline(
            state, now: date(28, 18), calendar: calendar,
            coveredBy: GroupCoverage.Holder(name: "Full break (Retreat)", isComplete: true)
        )

        XCTAssertTrue(sentence.hasPrefix("Blocked now by Full break (Retreat)"), sentence)
        XCTAssertTrue(sentence.contains("own block"), sentence)
    }

    func testHeadlineIsUnchangedWithoutAHolder() {
        let now = date(28, 18)
        let state = GroupNowStatus.evaluate(isEnabled: true, windows: [weekdays], now: now, calendar: calendar)

        XCTAssertEqual(
            GroupNowStatus.headline(state, now: now, calendar: calendar, coveredBy: nil),
            GroupNowStatus.headline(state, now: now, calendar: calendar)
        )
    }

    /// A pause buys nothing if the same sites are held by another group, and
    /// saying "Paused" alone would be the most misleading line on the screen.
    func testAPausedGroupSaysItIsStillBlocked() {
        let now = date(28, 12)
        let state = GroupNowStatus.evaluate(
            isEnabled: true, windows: [weekdays], now: now,
            allowanceUntil: date(28, 13), calendar: calendar
        )
        let sentence = GroupNowStatus.headline(
            state, now: now, calendar: calendar,
            coveredBy: GroupCoverage.Holder(name: "Full break", isComplete: true)
        )

        XCTAssertEqual(sentence, "Paused · still blocked now by Full break")
    }

    /// A group that is itself blocking needs no second opinion.
    func testABlockingGroupKeepsItsOwnSentence() {
        let now = date(28, 12)
        let state = GroupNowStatus.evaluate(isEnabled: true, windows: [weekdays], now: now, calendar: calendar)

        XCTAssertEqual(
            GroupNowStatus.headline(
                state, now: now, calendar: calendar,
                coveredBy: GroupCoverage.Holder(name: "Full break", isComplete: true)
            ),
            GroupNowStatus.headline(state, now: now, calendar: calendar)
        )
    }

    func testABlockingWindowIsOnlyAPlanWhileTheDeviceIsNotEnforcing() {
        let state = GroupNowStatus.evaluate(isEnabled: true, windows: [weekdays], now: date(29, 10), calendar: calendar)
        let unenforced = GroupNowStatus.headline(state, now: date(29, 10), calendar: calendar, coveredBy: nil, enforced: false)
        XCTAssertTrue(unenforced.hasPrefix("Scheduled until "), unenforced)
        XCTAssertTrue(unenforced.hasSuffix(" · not enforced"), unenforced)
        XCTAssertFalse(unenforced.localizedCaseInsensitiveContains("blocking"))
        XCTAssertEqual(
            GroupNowStatus.headline(state, now: date(29, 10), calendar: calendar, coveredBy: nil, enforced: true),
            GroupNowStatus.headline(state, now: date(29, 10), calendar: calendar))
        // States that claim nothing read the same either way.
        XCTAssertEqual(GroupNowStatus.headline(.off, now: date(29, 10), calendar: calendar, coveredBy: nil, enforced: false), "Off")
        // A Mac filter that is on but cannot vouch for the rules may still be
        // blocking, so the Mac says "not confirmed" rather than "not enforced".
        let unconfirmed = GroupNowStatus.headline(state, now: date(29, 10), calendar: calendar, coveredBy: nil,
                                                  enforced: false, unenforcedNote: GroupNowStatus.notConfirmed)
        XCTAssertTrue(unconfirmed.hasPrefix("Scheduled until "), unconfirmed)
        XCTAssertTrue(unconfirmed.hasSuffix(" · not confirmed"), unconfirmed)
    }
}
