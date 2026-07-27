import FamilyControls
import Foundation

enum EnforcementMode: String, Codable, CaseIterable, Identifiable {
    case blockList
    case fortressAllowList

    var id: Self { self }

    var title: String {
        switch self {
        case .blockList: "Block selected"
        case .fortressAllowList: "Fortress allow-list"
        }
    }

    var explanation: String {
        switch self {
        case .blockList:
            "Shield the selected apps, sites, and Apple categories while this rule is active."
        case .fortressAllowList:
            "Shield every app and site except selected app and domain tokens. The controller app remains available."
        }
    }
}

enum WebsiteCategory: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case social
    case video
    case news
    case shopping
    case gaming
    case adult
    case aiTools
    case productivity
    case education
    case finance
    case health
    case other

    var id: Self { self }

    var title: String {
        switch self {
        case .social: "Social"
        case .video: "Video & Streaming"
        case .news: "News"
        case .shopping: "Shopping"
        case .gaming: "Gaming"
        case .adult: "Adult"
        case .aiTools: "AI Tools"
        case .productivity: "Productivity"
        case .education: "Education"
        case .finance: "Finance"
        case .health: "Health"
        case .other: "Other"
        }
    }

    static var promptValues: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }
}

enum ClassificationSource: String, Codable, Sendable {
    case appleIntelligence
    case heuristic
    case user
}

struct ClassifiedDomain: Codable, Equatable, Identifiable, Hashable, Sendable {
    var domain: String
    var category: WebsiteCategory
    var source: ClassificationSource

    var id: String { domain }
}

struct TimeWindow: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    /// Calendar weekday values: Sunday = 1, Saturday = 7.
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    var startMinutes: Int = 9 * 60
    var endMinutes: Int = 17 * 60

    var startsAt: Date {
        get { Self.referenceDate(minutes: startMinutes) }
        set { startMinutes = Self.minutes(from: newValue) }
    }

    var endsAt: Date {
        get { Self.referenceDate(minutes: endMinutes) }
        set { endMinutes = Self.minutes(from: newValue) }
    }

    func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        weekdays.contains { occurrenceIsActive(startingOn: $0, at: date, calendar: calendar) }
    }

    /// Whether the occurrence of this window that begins on `startWeekday` covers `date`.
    /// Overnight windows (end at or before start) run into the following weekday.
    func occurrenceIsActive(startingOn startWeekday: Int, at date: Date, calendar: Calendar = .current) -> Bool {
        guard weekdays.contains(startWeekday) else { return false }
        let weekday = calendar.component(.weekday, from: date)
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)

        if startMinutes < endMinutes {
            return weekday == startWeekday && minute >= startMinutes && minute < endMinutes
        }

        return (weekday == startWeekday && minute >= startMinutes)
            || (weekday == endWeekday(for: startWeekday) && minute < endMinutes)
    }

    func endWeekday(for startWeekday: Int) -> Int {
        guard endMinutes <= startMinutes else { return startWeekday }
        return startWeekday == 7 ? 1 : startWeekday + 1
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

struct BlockingRule: Codable, Equatable, Identifiable {
    var id = UUID()
    /// Last change to the cross-device preference fields. Opaque Screen Time
    /// selection tokens are intentionally excluded from iCloud.
    var preferenceModifiedAt = Date()
    var name = "Focus rule"
    var isEnabled = true
    var enforcementMode: EnforcementMode = .blockList
    var selectionData = Data()
    var windows: [TimeWindow] = [TimeWindow()]
    var usageLimitEnabled = false
    var dailyUsageLimitMinutes = 30
    var classifiedDomains: [ClassifiedDomain] = []
    var websiteCategories: Set<WebsiteCategory> = []
    var lockdownPolicy = RuleLockdownPolicy()

    private enum CodingKeys: String, CodingKey {
        case id
        case preferenceModifiedAt
        case name
        case isEnabled
        case enforcementMode
        case selectionData
        case windows
        case usageLimitEnabled
        case dailyUsageLimitMinutes
        case classifiedDomains
        case websiteCategories
        case lockdownPolicy
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        preferenceModifiedAt = try values.decodeIfPresent(Date.self, forKey: .preferenceModifiedAt) ?? .distantPast
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Focus rule"
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        enforcementMode = try values.decodeIfPresent(EnforcementMode.self, forKey: .enforcementMode) ?? .blockList
        selectionData = try values.decodeIfPresent(Data.self, forKey: .selectionData) ?? Data()
        windows = try values.decodeIfPresent([TimeWindow].self, forKey: .windows) ?? [TimeWindow()]
        usageLimitEnabled = try values.decodeIfPresent(Bool.self, forKey: .usageLimitEnabled) ?? false
        dailyUsageLimitMinutes = try values.decodeIfPresent(Int.self, forKey: .dailyUsageLimitMinutes) ?? 30
        classifiedDomains = try values.decodeIfPresent([ClassifiedDomain].self, forKey: .classifiedDomains) ?? []
        websiteCategories = try values.decodeIfPresent(Set<WebsiteCategory>.self, forKey: .websiteCategories) ?? []
        lockdownPolicy = try values.decodeIfPresent(RuleLockdownPolicy.self, forKey: .lockdownPolicy)
            ?? RuleLockdownPolicy()
    }

    var selection: FamilyActivitySelection {
        get {
            guard !selectionData.isEmpty,
                  let decoded = try? JSONDecoder().decode(FamilyActivitySelection.self, from: selectionData)
            else { return FamilyActivitySelection() }
            return decoded
        }
        set {
            selectionData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    var selectedItemCount: Int {
        let value = selection
        return value.applicationTokens.count + value.categoryTokens.count + value.webDomainTokens.count
    }

    var enforcedDomains: Set<String> {
        Set(
            classifiedDomains
                .filter { websiteCategories.contains($0.category) }
                .map(\.domain)
        )
    }

    static var sample: BlockingRule {
        var rule = BlockingRule()
        rule.name = "Weekday focus"
        rule.websiteCategories = [.social, .video, .gaming]
        return rule
    }
}
