import SwiftUI

@main
struct ExecutiveDysfunctionMacApp: App {
    @StateObject private var model = MacAppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MacContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 620)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.refresh() }
                }
        }
        .defaultSize(width: 980, height: 720)
    }
}
