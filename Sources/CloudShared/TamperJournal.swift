import Foundation

/// Something that weakened, or tried to weaken, enforcement from outside the
/// normal passage/delay path.
///
/// Nothing on a device the owner administers can stop every bypass. What it
/// can do is make one undeniable: this journal records each event and the Mac
/// mirrors it through iCloud, so it shows up on the iPhone too (and can be
/// shown to an accountability partner). It never participates in enforcement.
struct TamperEvent: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// A `TamperEventKind` raw value. Stored as a string so an older build can
    /// still read a journal that contains kinds it does not know.
    var kind: String
    var detail: String
    var at: Date
    /// Which process noticed it: "mac-filter", "mac-app" or "ios-app".
    var origin: String

    var title: String {
        TamperEventKind(rawValue: kind)?.title ?? kind
    }
}

enum TamperEventKind: String, CaseIterable, Sendable {
    case clockTamperDetected
    case clockTamperCleared
    case filterDisabledOutsideApp
    case filterReenabledAutomatically
    case tunnelConfigurationAppeared
    case tunnelApplicationBlocked
    case emergencyDisable
    case removalRequested

    var title: String {
        switch self {
        case .clockTamperDetected: "System clock changed; enforcing both times"
        case .clockTamperCleared: "System clock back in agreement"
        case .filterDisabledOutsideApp: "Web filter turned off outside Holdfast"
        case .filterReenabledAutomatically: "Web filter turned back on"
        case .tunnelConfigurationAppeared: "New VPN or proxy configuration"
        case .tunnelApplicationBlocked: "VPN or proxy app blocked"
        case .emergencyDisable: "All web blocks disabled with passage"
        case .removalRequested: "Filter removal requested"
        }
    }
}

final class TamperJournal: @unchecked Sendable {
    static let shared = TamperJournal()
    static let storageKey = "tamper-journal.v1"
    static let maximumEvents = 500

    private let lock = NSLock()
    private var storage: (any KeyValueLedger)?
    private var origin = "unknown"
    private var memory: [TamperEvent] = []

    /// Until installed, events are kept in memory only (tests, previews).
    func install(storage: any KeyValueLedger, origin: String) {
        lock.lock()
        self.storage = storage
        self.origin = origin
        let stored = Self.decode(storage.data(forKey: Self.storageKey))
        memory = Self.merged(stored, memory)
        lock.unlock()
    }

    @discardableResult
    func record(
        _ kind: TamperEventKind,
        detail: String = "",
        at date: Date = Date(),
        id: UUID = UUID()
    ) -> TamperEvent {
        lock.lock()
        let event = TamperEvent(id: id, kind: kind.rawValue, detail: detail, at: date, origin: origin)
        memory = Self.merged(memory, [event])
        persistLocked()
        lock.unlock()
        return event
    }

    /// Folds in events noticed elsewhere (the filter's status file, iCloud).
    /// Returns true when anything new was added.
    @discardableResult
    func merge(_ incoming: [TamperEvent]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let next = Self.merged(memory, incoming)
        guard next != memory else { return false }
        memory = next
        persistLocked()
        return true
    }

    func events() -> [TamperEvent] {
        lock.lock()
        defer { lock.unlock() }
        return memory
    }

    func reset() {
        lock.lock()
        memory = []
        storage?.removeObject(forKey: Self.storageKey)
        lock.unlock()
    }

    private func persistLocked() {
        guard let storage, let data = try? JSONEncoder().encode(memory) else { return }
        storage.set(data, forKey: Self.storageKey)
    }

    /// Oldest first, unique by id, bounded to the newest `maximumEvents`.
    static func merged(_ existing: [TamperEvent], _ incoming: [TamperEvent]) -> [TamperEvent] {
        var seen = Set<UUID>()
        let all = (existing + incoming).filter { seen.insert($0.id).inserted }
            .sorted { $0.at == $1.at ? $0.id.uuidString < $1.id.uuidString : $0.at < $1.at }
        return Array(all.suffix(maximumEvents))
    }

    static func decode(_ data: Data?) -> [TamperEvent] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([TamperEvent].self, from: data)) ?? []
    }
}

/// The journal's iCloud copy, readable on every device signed into the account.
enum TamperJournalCloudMirror {
    static let key = "holdfast.tamper-journal.v1"
    /// Key-value storage allows 1 MB per key; 200 events stay far below that.
    static let maximumEvents = 200

    static func read(from store: NSUbiquitousKeyValueStore = .default) -> [TamperEvent] {
        TamperJournal.decode(store.data(forKey: key))
    }

    /// Additive: events already mirrored by another device are kept.
    @discardableResult
    static func publish(_ events: [TamperEvent], to store: NSUbiquitousKeyValueStore = .default) -> Bool {
        let existing = read(from: store)
        let merged = Array(TamperJournal.merged(existing, events).suffix(maximumEvents))
        guard merged != existing, let data = try? JSONEncoder().encode(merged) else { return false }
        store.set(data, forKey: key)
        return true
    }
}
