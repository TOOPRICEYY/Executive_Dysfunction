import XCTest
#if !DESKTOP_HOSTLESS_TESTS
@testable import Holdfast
#endif

final class BypassHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func defaults() -> UserDefaults {
        let name = "bypass-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }
    private func event(intent: BypassEvent.Intent? = nil, source: BypassEvent.Source = .app) -> BypassEvent {
        BypassEvent(id: UUID(), groupID: UUID(), groupName: "News", grantedAt: now,
                    expiresAt: now.addingTimeInterval(600), grantedMinutes: 10, source: source, intent: intent)
    }

    func testBothIntentionsRoundTripAndRepeatImportDoesNotDoubleCount() throws {
        let store = defaults()
        let events = [event(intent: .consciousIntervention), event(intent: .eDulgance, source: .browser)]
        XCTAssertTrue(BypassHistoryStore.record(events, defaults: store, at: now))
        let data = store.data(forKey: BypassHistoryStore.key)
        XCTAssertTrue(BypassHistoryStore.record(events, defaults: store, at: now))
        XCTAssertEqual(store.data(forKey: BypassHistoryStore.key), data)
        let history = BypassHistoryStore.read(defaults: store, at: now.addingTimeInterval(86_400)).document.events
        XCTAssertEqual(Set(history.map(\.id)), Set(events.map(\.id)))
        XCTAssertEqual(Set(history.compactMap(\.intent)), [.consciousIntervention, .eDulgance])
    }

    func testOlderRecordWithoutIntentIsUnspecified() throws {
        let encoded = try JSONEncoder().encode(event())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "intent")
        let decoded = try JSONDecoder().decode(BypassEvent.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.intent)
        XCTAssertNil(BypassEvent.Intent(rawValue: "unknown"))
    }

    func testCorruptHistoryIsPreservedAndInvalidEventsAreIgnored() {
        let store = defaults()
        let corrupt = Data("broken".utf8)
        store.set(corrupt, forKey: BypassHistoryStore.key)
        XCTAssertFalse(BypassHistoryStore.record([event()], defaults: store, at: now))
        XCTAssertNotNil(BypassHistoryStore.read(defaults: store).error)
        XCTAssertEqual(store.data(forKey: BypassHistoryStore.key), corrupt)
        let clean = defaults()
        var invalid = event(); invalid.expiresAt = invalid.grantedAt
        var future = event(); future.grantedAt = now.addingTimeInterval(60)
        XCTAssertTrue(BypassHistoryStore.record([invalid, future], defaults: clean, at: now))
        XCTAssertTrue(BypassHistoryStore.read(defaults: clean).document.events.isEmpty)
    }

    func testHistoryIsBoundedAndOldImportsDoNotDisplaceRecentEvents() {
        let store = defaults()
        let events = (0...BypassHistoryStore.maximumEvents).map { index in
            var value = event()
            value.grantedAt = now.addingTimeInterval(Double(index - BypassHistoryStore.maximumEvents))
            value.expiresAt = value.grantedAt.addingTimeInterval(600)
            return value
        }
        BypassHistoryStore.record(events, defaults: store, at: now)
        let before = store.data(forKey: BypassHistoryStore.key)
        BypassHistoryStore.record([events[0]], defaults: store, at: now)
        let snapshot = BypassHistoryStore.read(defaults: store)
        XCTAssertTrue(snapshot.document.wasTruncated)
        XCTAssertEqual(snapshot.document.events.count, BypassHistoryStore.maximumEvents)
        XCTAssertEqual(store.data(forKey: BypassHistoryStore.key), before)
    }

    func testFiltersAndGroupSummariesKeepZeroRenamedAndRemovedGroups() {
        let first = event(intent: .consciousIntervention)
        var second = event(intent: .eDulgance, source: .browser); second.groupID = first.groupID
        let removed = event()
        let all = [first, second, removed, first]
        let filtered = BypassReport.events(all, from: now, through: now, intent: "consciousIntervention")
        XCTAssertEqual(filtered, [first])
        XCTAssertEqual(BypassReport.events(all, from: now, through: now, source: .browser), [second])
        XCTAssertEqual(BypassReport.events(all, from: now, through: now, intent: "unspecified"), [removed])
        XCTAssertTrue(BypassReport.events(all, from: now.addingTimeInterval(1), through: now.addingTimeInterval(10)).isEmpty)
        let zeroID = UUID()
        let rows = BypassReport.summaries(events: BypassReport.events(all, from: now, through: now),
            groups: [.init(id: first.groupID, name: "Renamed"), .init(id: zeroID, name: "Unused")])
        XCTAssertEqual(rows.first?.name, "Renamed")
        XCTAssertEqual(rows.first?.count, 2)
        XCTAssertEqual(rows.first?.minutes, 20)
        XCTAssertEqual(rows.first { $0.id == zeroID }?.count, 0)
        XCTAssertEqual(rows.first { $0.id == removed.groupID }?.isRemoved, true)
    }

    func testPeriodUsesCalendarDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: now)
        XCTAssertEqual(BypassReport.Period.today.start(at: now, calendar: calendar), start)
        XCTAssertEqual(BypassReport.Period.week.start(at: now, calendar: calendar), start.addingTimeInterval(-6 * 86_400))
    }
}

final class EmergencyDisableHistoryTests: XCTestCase {
    func testEmergencyDisableIsRecordedAgainstAllWebBlocks() throws {
        let suite = "EmergencyDisableHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)

        let healthy = BypassEvent.emergencyDisable(at: now, recoveryWarningLive: false)
        let warning = BypassEvent.emergencyDisable(at: now.addingTimeInterval(10), recoveryWarningLive: true)
        XCTAssertTrue(healthy.isValid)
        XCTAssertTrue(BypassHistoryStore.record([healthy, warning], defaults: defaults, at: now.addingTimeInterval(10)))

        let events = BypassHistoryStore.read(defaults: defaults, at: now).document.events
        XCTAssertEqual(events.map(\.source), [.emergencyDisable, .emergencyDisable])
        XCTAssertEqual(Set(events.map(\.groupID)), [BypassEvent.allWebBlocksGroupID])
        XCTAssertNotEqual(events[0].groupName, events[1].groupName, "The warning state is visible in the record")
        XCTAssertEqual(BypassEvent.Source.emergencyDisable.title, "Emergency disable")
    }
}
