import SwiftUI

@main
struct HoldfastMacApp: App {
    @StateObject private var model: MacAppModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MacInterfaceTheme.storageKey) private var storedTheme = MacInterfaceTheme.light.rawValue
    @AppStorage(MacHighlightColor.storageKey) private var storedHighlight = MacHighlightColor.defaultValue.rawValue

    init() {
        if CommandLine.arguments.contains(MacEnforcementSafetyStateReporter.argument) {
            MacEnforcementSafetyStateReporter.reportAndExit()
        }
        _model = StateObject(wrappedValue: MacAppModel(
            uiPreviewMode: CommandLine.arguments.contains("--ui-preview")
        ))
    }

    var body: some Scene {
        WindowGroup {
            MacContentView()
                .environmentObject(model)
                .frame(minWidth: 1240, minHeight: 700)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.refresh() }
                }
        }
        .defaultSize(width: 1320, height: 840)
        WindowGroup("Bypass history", id: "bypass-history", for: String.self) { $selection in
            BypassHistoryDetailView(groups: model.rules.map { .init(id: $0.id, name: $0.name) },
                defaults: .standard, initialGroupID: selection.flatMap(UUID.init(uuidString:)),
                coverageNote: "This Mac only. Browser history requires the updated filter and block-page helper; the helper retains its latest 1,000 grants for import.")
                .background(MacBrutalPalette.canvas)
                .preferredColorScheme((MacInterfaceTheme(rawValue: storedTheme) ?? .light).colorScheme)
                .tint(historyAccent)
        }
        .defaultSize(width: 880, height: 720)
    }

    private var historyAccent: Color {
        let isDark = storedTheme == MacInterfaceTheme.dark.rawValue
        let color = (MacHighlightColor(rawValue: storedHighlight) ?? .defaultValue).nsColor(isDark: isDark)
        return Color(nsColor: isDark ? color : (color.blended(withFraction: 0.5, of: .black) ?? color))
    }
}
