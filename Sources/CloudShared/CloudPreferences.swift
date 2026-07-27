import Foundation

struct CloudPreferencesDocument: Codable, Equatable {
    var schemaVersion = 1
    var rules: [CloudRulePreference] = []
    var tombstones: [CloudRuleTombstone] = []

    mutating func merge(rule: CloudRulePreference) {
        if let tombstone = tombstones.first(where: { $0.id == rule.id }),
           tombstone.modifiedAt >= rule.modifiedAt { return }
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            guard rules[index].modifiedAt <= rule.modifiedAt else { return }
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        tombstones.removeAll { $0.id == rule.id && $0.modifiedAt <= rule.modifiedAt }
    }

    mutating func merge(tombstone: CloudRuleTombstone) {
        if let rule = rules.first(where: { $0.id == tombstone.id }),
           rule.modifiedAt > tombstone.modifiedAt { return }
        if let index = tombstones.firstIndex(where: { $0.id == tombstone.id }) {
            guard tombstones[index].modifiedAt <= tombstone.modifiedAt else { return }
            tombstones[index] = tombstone
        } else {
            tombstones.append(tombstone)
        }
        rules.removeAll { $0.id == tombstone.id && $0.modifiedAt <= tombstone.modifiedAt }
    }
}

struct CloudRulePreference: Codable, Equatable, Identifiable {
    var id = UUID()
    var modifiedAt = Date()
    var name = "Focus rule"
    var isEnabled = true
    var enforcementMode = "blockList"
    var windows: [CloudTimeWindow] = [CloudTimeWindow()]
    var usageLimitEnabled = false
    var dailyUsageLimitMinutes = 30
    var domains: [CloudDomainPreference] = []
    var websiteCategories: Set<String> = []
    /// Stable macOS code-signing identifiers (normally bundle identifiers).
    /// Unlike Screen Time tokens, these are portable and can be enforced by an
    /// administrator-approved Endpoint Security system extension.
    var macApplicationIdentifiers: Set<String> = []
    /// Normalized Windows executable paths. Production Windows deployments
    /// should prefer publisher rules where available so application updates do
    /// not silently move outside the rule.
    var windowsExecutablePaths: Set<String> = []
    var windowsPublisherRules: Set<String> = []
    var lockdown = CloudRuleLockdownPreference()
    /// Informational only. Opaque Screen Time tokens never leave the iPhone.
    var deviceLocalSelectionCount = 0
}

extension CloudRulePreference {
    private enum CodingKeys: String, CodingKey {
        case id, modifiedAt, name, isEnabled, enforcementMode, windows
        case usageLimitEnabled, dailyUsageLimitMinutes, domains, websiteCategories
        case macApplicationIdentifiers, windowsExecutablePaths, windowsPublisherRules
        case lockdown, deviceLocalSelectionCount
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        modifiedAt = try values.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? .distantPast
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Focus rule"
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        enforcementMode = try values.decodeIfPresent(String.self, forKey: .enforcementMode) ?? "blockList"
        windows = try values.decodeIfPresent([CloudTimeWindow].self, forKey: .windows) ?? [CloudTimeWindow()]
        usageLimitEnabled = try values.decodeIfPresent(Bool.self, forKey: .usageLimitEnabled) ?? false
        dailyUsageLimitMinutes = try values.decodeIfPresent(Int.self, forKey: .dailyUsageLimitMinutes) ?? 30
        domains = try values.decodeIfPresent([CloudDomainPreference].self, forKey: .domains) ?? []
        websiteCategories = try values.decodeIfPresent(Set<String>.self, forKey: .websiteCategories) ?? []
        macApplicationIdentifiers = try values.decodeIfPresent(Set<String>.self, forKey: .macApplicationIdentifiers) ?? []
        windowsExecutablePaths = try values.decodeIfPresent(Set<String>.self, forKey: .windowsExecutablePaths) ?? []
        windowsPublisherRules = try values.decodeIfPresent(Set<String>.self, forKey: .windowsPublisherRules) ?? []
        lockdown = try values.decodeIfPresent(CloudRuleLockdownPreference.self, forKey: .lockdown)
            ?? CloudRuleLockdownPreference()
        deviceLocalSelectionCount = try values.decodeIfPresent(Int.self, forKey: .deviceLocalSelectionCount) ?? 0
    }
}

struct CloudTimeWindow: Codable, Equatable, Identifiable {
    var id = UUID()
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    var startMinutes = 9 * 60
    var endMinutes = 17 * 60

    var startsAt: Date {
        get { Self.referenceDate(minutes: startMinutes) }
        set { startMinutes = Self.minutes(from: newValue) }
    }

    var endsAt: Date {
        get { Self.referenceDate(minutes: endMinutes) }
        set { endMinutes = Self.minutes(from: newValue) }
    }

    private static func referenceDate(minutes: Int) -> Date {
        Calendar.current.date(
            bySettingHour: max(0, min(23, minutes / 60)),
            minute: max(0, min(59, minutes % 60)),
            second: 0,
            of: Date()
        ) ?? Date()
    }

    private static func minutes(from date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

struct CloudDomainPreference: Codable, Equatable, Identifiable {
    var domain: String
    var category: String
    var source: String
    var id: String { domain }
}

struct CloudRuleLockdownPreference: Codable, Equatable {
    var severity = "appDefault"
    var unlockDelayDays = 3
    var passageWordCount = 40
    var confirmationWindowHours = 24
    var editWindowHours = 24
    var allowsTimeExtensions = false
    var maximumTimeExtensionHours = 3
}

extension CloudRuleLockdownPreference {
    private enum CodingKeys: String, CodingKey {
        case severity, unlockDelayDays, passageWordCount
        case confirmationWindowHours, editWindowHours
        case allowsTimeExtensions, maximumTimeExtensionHours
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        severity = try values.decodeIfPresent(String.self, forKey: .severity) ?? "appDefault"
        unlockDelayDays = try values.decodeIfPresent(Int.self, forKey: .unlockDelayDays) ?? 3
        passageWordCount = try values.decodeIfPresent(Int.self, forKey: .passageWordCount) ?? 40
        confirmationWindowHours = try values.decodeIfPresent(Int.self, forKey: .confirmationWindowHours) ?? 24
        editWindowHours = try values.decodeIfPresent(Int.self, forKey: .editWindowHours) ?? 24
        allowsTimeExtensions = try values.decodeIfPresent(Bool.self, forKey: .allowsTimeExtensions) ?? false
        maximumTimeExtensionHours = try values.decodeIfPresent(Int.self, forKey: .maximumTimeExtensionHours) ?? 3
    }
}

struct CloudRuleTombstone: Codable, Equatable, Identifiable {
    var id: UUID
    var modifiedAt: Date
}

enum ICloudPreferencesError: LocalizedError {
    case documentTooLarge(Int)
    case corruptDocument

    var errorDescription: String? {
        switch self {
        case let .documentTooLarge(bytes):
            "The iCloud preference document is too large (\(bytes) bytes). Remove rules or domains."
        case .corruptDocument:
            "The iCloud preference document could not be decoded."
        }
    }
}

final class ICloudPreferencesStore {
    static let documentKey = "executive-dysfunction.preferences.v1"
    static let maximumDocumentBytes = 900_000

    private let store: NSUbiquitousKeyValueStore

    init(store: NSUbiquitousKeyValueStore = .default) {
        self.store = store
    }

    @discardableResult
    func synchronize() -> Bool {
        store.synchronize()
    }

    func load() throws -> CloudPreferencesDocument {
        guard let data = store.data(forKey: Self.documentKey) else {
            return CloudPreferencesDocument()
        }
        guard let document = try? JSONDecoder().decode(CloudPreferencesDocument.self, from: data) else {
            throw ICloudPreferencesError.corruptDocument
        }
        return document
    }

    func save(_ document: CloudPreferencesDocument) throws {
        let data = try JSONEncoder().encode(document)
        guard data.count <= Self.maximumDocumentBytes else {
            throw ICloudPreferencesError.documentTooLarge(data.count)
        }
        store.set(data, forKey: Self.documentKey)
        store.synchronize()
    }

    func merge(
        rules: [CloudRulePreference] = [],
        tombstones: [CloudRuleTombstone] = []
    ) throws -> CloudPreferencesDocument {
        var document = try load()
        rules.forEach { document.merge(rule: $0) }
        tombstones.forEach { document.merge(tombstone: $0) }
        try save(document)
        return document
    }
}
