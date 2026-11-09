import Foundation

/// The small key-value surface the lock and pause ledgers need.
///
/// `UserDefaults` satisfies it unchanged, which keeps iOS (whose app-group
/// container the user cannot reach) and the hostless tests as they were. On
/// macOS the same ledgers move to `KeychainProtectedLedger`, because the Mac
/// app's preference files are ordinary user-owned plists: editing one by hand
/// could otherwise backdate an unlock or grant an unlimited pause.
protocol KeyValueLedger: AnyObject {
    func data(forKey defaultName: String) -> Data?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: KeyValueLedger {}

/// Deterministic in-memory ledger for tests and previews.
final class InMemoryKeyValueLedger: KeyValueLedger {
    private(set) var values: [String: Data] = [:]

    init(values: [String: Data] = [:]) {
        self.values = values
    }

    func data(forKey defaultName: String) -> Data? {
        values[defaultName]
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value as? Data
    }

    func removeObject(forKey defaultName: String) {
        values[defaultName] = nil
    }
}
