import FamilyControls
import Foundation

/// Family Controls tokens are opaque and device-bound. Activity Groups are
/// portable, but their iPhone/iPad selections must remain in the shared local
/// container and be reattached whenever the portable document is compiled into
/// Screen Time rules.
enum ActivityGroupSelectionPersistence {
    private static let key = "activity-group.local-selections.v1"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: SharedConfiguration.appGroupIdentifier) ?? .standard
    }

    static func selection(for id: UUID) -> FamilyActivitySelection {
        guard let data = load()[id.uuidString],
              let value = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        else { return FamilyActivitySelection() }
        return value
    }

    static func hasSelection(for id: UUID) -> Bool {
        load()[id.uuidString] != nil
    }

    static func save(_ selection: FamilyActivitySelection, for id: UUID) {
        var values = load()
        values[id.uuidString] = try? JSONEncoder().encode(selection)
        defaults.set(try? JSONEncoder().encode(values), forKey: key)
    }

    static func remove(_ id: UUID) {
        var values = load()
        values[id.uuidString] = nil
        defaults.set(try? JSONEncoder().encode(values), forKey: key)
    }

    static func seedLegacySelection(_ data: Data, for id: UUID) {
        guard !data.isEmpty, !hasSelection(for: id),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        else { return }
        save(selection, for: id)
    }

    static func selectedItemCount(for id: UUID) -> Int {
        let selection = selection(for: id)
        return selection.applicationTokens.count
            + selection.categoryTokens.count
            + selection.webDomainTokens.count
    }

    private static func load() -> [String: Data] {
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode([String: Data].self, from: data)
        else { return [:] }
        return values
    }
}
