#if os(macOS)
import AppKit
import SwiftUI
import HoldfastSharedInterface

// Isolated developer preview: not the installed Holdfast app, no model/enforcer,
// no iCloud, no policy commands, and an ephemeral WebKit data store.
@main
struct Preview {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: HoldfastSharedUIPreview /absolute/path/to/SharedUI/dist\n", stderr); return
        }
        let assets = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard FileManager.default.fileExists(atPath: assets.appendingPathComponent("index.html").path) else {
            fputs("Build SharedUI first: npm ci && npm run build\n", stderr); return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let view = HoldfastWebView(assets: assets, preview: true) { _ in
            throw NSError(domain: "Preview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Native commands are unavailable in preview."])
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Holdfast — Shared UI preview (no enforcement)"
        window.contentView = NSHostingView(rootView: view)
        window.center(); window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}
#else
@main struct Preview { static func main() {} }
#endif
