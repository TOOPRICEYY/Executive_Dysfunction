import SwiftUI

@main
struct HoldfastApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            SharedInterfaceScreen(model: model)
                .environmentObject(model)
                .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { _ in
                    model.syncICloudPreferences()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            model.refreshAuthorizationAndEnforcement()
        }
    }
}
