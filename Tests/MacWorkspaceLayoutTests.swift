#if os(macOS)
import AppKit
import SwiftUI
import XCTest

final class MacWorkspaceLayoutTests: XCTestCase {
    @MainActor
    func testBypassPanelRendersBelowDashboardCalendar() throws {
        let name = "bypass-footer-layout-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try capture("dashboard-bypass-footer", scheme: .light, width: 880, height: 1600, content:
            MacDashboardView(activeRules: [], calendarRules: [], baselineRules: [], retreats: [],
                onEdit: { _ in }, onAdd: {}, onOpenRetreats: {}, onOpenRetreat: { _ in },
                bypassPanel: BypassActivityPanel(groups: [], defaults: defaults)) {
                    Text("Web enforcement status").padding(16)
                })
    }
    @MainActor
    func testBypassViewsAndIntentionChoicesFitBothThemes() throws {
        let name = "bypass-layout-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let groups = [BypassReport.Group(id: UUID(), name: "News & social feeds")]
        BypassHistoryStore.record([.init(id: UUID(), groupID: groups[0].id, groupName: groups[0].name,
            grantedAt: Date(), expiresAt: Date().addingTimeInterval(600), grantedMinutes: 10,
            source: .app, intent: .consciousIntervention)], defaults: defaults)
        for scheme in [ColorScheme.light, .dark] {
            try capture("bypass-intention-\(scheme)", scheme: scheme, width: 360, content:
                VStack(alignment: .leading, spacing: 24) {
                    BypassIntentPicker(selection: .constant(.consciousIntervention))
                    BypassIntentPicker(selection: .constant(.eDulgance))
                    BypassActivityPanel(groups: groups, defaults: defaults)
                }.padding(16))
            try capture("bypass-history-\(scheme)", scheme: scheme, width: 880, content:
                BypassHistoryDetailView(groups: groups, defaults: defaults))
        }
    }
    @MainActor
    func testLockdownOverridesDisabledGroupStatusWithoutLosingSchedule() throws {
        var rule = CloudRulePreference(name: "Social feeds")
        rule.isEnabled = false
        let start = Date()
        let end = start.addingTimeInterval(3_600)
        try capture("dashboard-lockdown", scheme: .dark, content:
            MacDashboardView(activeRules: [rule], calendarRules: [BlockStatusCalendarRule(rule: rule, forcedIntervals: [DateInterval(start: start, end: end)])],
                baselineRules: [rule], retreats: [], lockdownExpirations: [rule.id: end],
                onEdit: { _ in }, onAdd: {}, onOpenRetreats: {}, onOpenRetreat: { _ in }) {
                    LockdownStatusBadge(endsAt: end).padding(16)
                })
    }
    @MainActor
    func testTemporaryAllowanceAppearsInDashboardAndEditSummary() throws {
        var rule = CloudRulePreference(name: "Social feeds")
        rule.isEnabled = true
        let expiry = Date().addingTimeInterval(1800)
        try capture("dashboard-temporarily-allowed", scheme: .dark, content:
            MacDashboardView(activeRules: [], calendarRules: [], baselineRules: [rule], retreats: [],
                temporaryAllowances: [rule.id: expiry], onEdit: { _ in }, onAdd: {}, onOpenRetreats: {}, onOpenRetreat: { _ in }) { EmptyView() })
        try capture("allowance-backoff-edit-summary", scheme: .light, width: 540, content:
            VStack(alignment: .leading, spacing: 16) {
                TemporaryAllowanceStatusView(expiresAt: expiry)
                BlockingSchedulePreviewView(plan: CloudTimeWindowPlan())
                TemporaryAllowanceBackoffEditor(resetDays: .constant(7))
            }.padding(24).frame(maxHeight: .infinity, alignment: .top).background(MacBrutalPalette.canvas))
    }

    @MainActor
    func testBlockingSchedulePreviewFitsCompactWidthInBothThemes() throws {
        let plan = CloudTimeWindowPlan(paintMode: .allow, slots: [
            .init(weekdays: [2, 3, 4, 5, 6], startMinutes: 720, endMinutes: 780),
            .init(weekdays: [1, 7], startMinutes: 1080, endMinutes: 1320)
        ])
        for scheme in [ColorScheme.light, .dark] {
            try capture("schedule-preview-\(scheme)", scheme: scheme, width: 340, content:
                BlockingSchedulePreviewView(plan: plan, isEnabled: false, hasUsageLimit: true)
                    .padding(20).frame(maxHeight: .infinity, alignment: .top)
                    .background(MacBrutalPalette.canvas))
        }
    }

    @MainActor
    func testNarrowWorkspaceDoesNotRequireSideBySidePanels() throws {
        var rule = CloudRulePreference(name: "A longer group name for reading and news")
        rule.isEnabled = false
        try capture("dashboard-narrow", scheme: .light, width: 700, content:
            MacDashboardView(activeRules: [], calendarRules: [], baselineRules: [rule], retreats: [],
                             onEdit: { _ in }, onAdd: {}, onOpenRetreats: {}, onOpenRetreat: { _ in }) { EmptyView() })
        try capture("retreat-narrow", scheme: .light, width: 700, content:
            MacRetreatComposerView(baselineGroups: [], retreats: [], initialRetreat: nil,
                                   onOpenRetreat: { _ in }, onSave: { _ in }))
    }

    @MainActor
    func testWorkspaceScreensRenderInBothThemes() throws {
        var rule = CloudRulePreference(name: "Social feeds")
        rule.isEnabled = true
        let group = CloudBlockingGroup(name: "Social feeds")
        for scheme in [ColorScheme.light, .dark] {
            try capture("dashboard-\(scheme)", scheme: scheme, content:
                MacDashboardView(activeRules: [rule], calendarRules: [BlockStatusCalendarRule(rule: rule)], baselineRules: [rule], retreats: [],
                                 onEdit: { _ in }, onAdd: {}, onOpenRetreats: {}, onOpenRetreat: { _ in }) {
                    Text("Web enforcement is enabled").padding(16)
                })
            try capture("retreat-\(scheme)", scheme: scheme, content:
                MacRetreatComposerView(baselineGroups: [group], retreats: [], initialRetreat: nil,
                                       onOpenRetreat: { _ in }, onSave: { _ in }))
            try capture("history-\(scheme)", scheme: scheme, content:
                MacRetreatHistoryView(retreats: [], onEnd: { _, _ in }, onOpen: { _ in }))
            try capture("settings-\(scheme)", scheme: scheme, content: MacSettingsView())
        }
    }

    @MainActor
    private func capture<V: View>(_ name: String, scheme: ColorScheme, width: CGFloat = 1080, height: CGFloat = 840, content: V) throws {
        let size = NSSize(width: width, height: height)
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        // NavigationStack and .task-driven snapshots need a run-loop turn.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, size.width, accuracy: 1)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        window.close()
    }
}
#endif
