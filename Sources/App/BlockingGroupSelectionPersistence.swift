import FamilyControls
import Foundation

enum BlockingGroupSelectionPersistence {
    private static var defaults: UserDefaults { UserDefaults(suiteName: SharedConfiguration.appGroupIdentifier) ?? .standard }
    private static func key(_ id: UUID) -> String { "blocking-group.selection.v1.\(id.uuidString)" }
    static func data(for id: UUID) -> Data? { defaults.data(forKey: key(id)) }
    static func restore(_ data: Data?, for id: UUID) {
        if let data { defaults.set(data, forKey: key(id)) } else { defaults.removeObject(forKey: key(id)) }
    }
    static func selection(for id: UUID) -> FamilyActivitySelection? {
        data(for: id).flatMap { try? JSONDecoder().decode(FamilyActivitySelection.self, from: $0) }
    }
    static func save(_ selection: FamilyActivitySelection, for id: UUID) {
        restore(try? JSONEncoder().encode(selection), for: id)
    }
}
