import SwiftUI

@main
struct ExecutiveDysfunctionApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            model.refreshAuthorizationAndEnforcement()
        }
    }
}

