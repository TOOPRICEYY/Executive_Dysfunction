import Foundation

/// Optional reporting data must never make an enforcement document unreadable.
@propertyWrapper
struct BypassEventBuffer: Codable, Equatable, Sendable {
    var wrappedValue: [BypassEvent]?
    init(wrappedValue: [BypassEvent]? = nil) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        wrappedValue = try? decoder.singleValueContainer().decode([BypassEvent].self)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: BypassEventBuffer.Type, forKey key: Key) throws -> BypassEventBuffer {
        try decodeIfPresent(type, forKey: key) ?? BypassEventBuffer()
    }
}

/// Successful temporary-access authorizations, not visits, edit unlocks or
/// measured browsing time. This history never participates in enforcement.
struct BypassEvent: Codable, Equatable, Identifiable, Sendable {
    enum Intent: String, Codable, CaseIterable, Sendable {
        case consciousIntervention, eDulgance
        var title: String { self == .consciousIntervention ? "Conscious intervention" : "e-dulgance" }
    }
    enum Source: String, Codable, CaseIterable, Sendable {
        case app, browser
        var title: String { self == .app ? "App" : "Block page" }
    }
    var id: UUID
    var groupID: UUID
    var groupName: String
    var grantedAt: Date
    var expiresAt: Date
    var grantedMinutes: Int
    var source: Source
    var intent: Intent? = nil

    var isValid: Bool {
        grantedAt.timeIntervalSince1970.isFinite && expiresAt.timeIntervalSince1970.isFinite
            && expiresAt > grantedAt && (1...480).contains(grantedMinutes)
    }
}

enum BypassHistoryStore {
    static let key = "bypass-history.events.v1"
    static let maximumEvents = 10_000
    private static let lock = NSRecursiveLock()

    struct Document: Codable, Equatable {
        var schemaVersion = 1
        var startedAt: Date
        var events: [BypassEvent] = []
        var wasTruncated = false
    }
    struct Snapshot {
        var document: Document
        var error: String? = nil
    }

    static func read(defaults: UserDefaults, at now: Date = Date()) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: key) else {
            let document = Document(startedAt: now)
            defaults.set(try? JSONEncoder().encode(document), forKey: key)
            return Snapshot(document: document)
        }
        guard let document = try? JSONDecoder().decode(Document.self, from: data), document.schemaVersion == 1 else {
            return Snapshot(document: Document(startedAt: now), error: "Bypass history could not be read. Existing data has been left untouched.")
        }
        return Snapshot(document: document)
    }

    /// Stable request IDs deduplicate repeated status imports. Grant extensions
    /// have distinct IDs and count separately. Never backfill resettable backoff
    /// counters: those cannot reconstruct timestamps or lifetime totals.
    @discardableResult
    static func record(_ events: [BypassEvent], defaults: UserDefaults, at now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let snapshot = read(defaults: defaults, at: now)
        guard snapshot.error == nil else { return false }
        var document = snapshot.document
        var known = Set(document.events.map(\.id))
        let additions = events.filter { $0.isValid && $0.grantedAt <= now.addingTimeInterval(5) && known.insert($0.id).inserted }
        guard !additions.isEmpty else { return true }
        document.events += additions
        document.events.sort { $0.grantedAt == $1.grantedAt ? $0.id.uuidString < $1.id.uuidString : $0.grantedAt < $1.grantedAt }
        if document.events.count > maximumEvents {
            document.events = Array(document.events.suffix(maximumEvents))
            document.wasTruncated = true
        }
        guard document != snapshot.document else { return true }
        guard let data = try? JSONEncoder().encode(document) else { return false }
        defaults.set(data, forKey: key)
        return true
    }
}

enum BypassReport {
    enum Period: String, CaseIterable, Identifiable {
        case today, week, month, quarter, all, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .today: "Today"
            case .week: "Last 7 days"
            case .month: "Last 30 days"
            case .quarter: "Last 90 days"
            case .all: "All recorded"
            case .custom: "Custom dates"
            }
        }
        func start(at now: Date, calendar: Calendar = .current) -> Date {
            let days: Int
            switch self {
            case .today: days = 0
            case .week: days = 6
            case .month: days = 29
            case .quarter: days = 89
            case .all, .custom: return .distantPast
            }
            return calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) ?? now
        }
    }
    struct Group: Equatable, Identifiable {
        var id: UUID
        var name: String
    }
    struct Summary: Identifiable {
        var id: UUID
        var name: String
        var count: Int
        var minutes: Int
        var latest: Date?
        var isRemoved: Bool
    }

    static func events(_ events: [BypassEvent], from start: Date, through end: Date,
                       groupID: UUID? = nil, source: BypassEvent.Source? = nil,
                       intent: String = "all") -> [BypassEvent] {
        var known: Set<UUID> = []
        return events.filter {
            $0.isValid && $0.grantedAt >= start && $0.grantedAt <= end
                && (groupID == nil || $0.groupID == groupID)
                && (source == nil || $0.source == source) && known.insert($0.id).inserted
                && (intent == "all" || ($0.intent?.rawValue ?? "unspecified") == intent)
        }.sorted { $0.grantedAt == $1.grantedAt ? $0.id.uuidString < $1.id.uuidString : $0.grantedAt > $1.grantedAt }
    }

    static func summaries(events: [BypassEvent], groups: [Group]) -> [Summary] {
        let names = Dictionary(groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var result = Dictionary(uniqueKeysWithValues: names.map { id, name in
            (id, Summary(id: id, name: name, count: 0, minutes: 0, isRemoved: false))
        })
        for event in events {
            var row = result[event.groupID] ?? Summary(id: event.groupID, name: event.groupName, count: 0, minutes: 0, isRemoved: true)
            row.count += 1
            row.minutes += event.grantedMinutes
            if row.latest == nil || event.grantedAt > row.latest! {
                row.latest = event.grantedAt
                if row.isRemoved { row.name = event.groupName }
            }
            result[event.groupID] = row
        }
        return result.values.sorted {
            $0.count == $1.count ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.count > $1.count
        }
    }
}
