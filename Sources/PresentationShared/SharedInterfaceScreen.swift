import SwiftUI
#if os(iOS)
import FamilyControls
#endif

/// The packaged web bundle is the same build as Windows. Only OS pickers,
/// diagnostics and the existing advanced editors are native during migration.
struct SharedInterfaceScreen: View {
    @StateObject private var session: SharedInterfaceSession
    @ObservedObject private var model: SharedInterfaceNativeModel
    @AppStorage("executiveDysfunction.interfaceTheme") private var appearanceTheme = "light"
    init(model: SharedInterfaceNativeModel) {
        self.model = model
        _session = StateObject(wrappedValue: SharedInterfaceSession(model: model))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let assets = Bundle.main.resourceURL?.appendingPathComponent("SharedUI"),
               FileManager.default.fileExists(atPath: assets.appendingPathComponent("index.html").path) {
                HoldfastWebView(assets: assets) { data in try await session.handle(data) }
                    #if os(iOS)
                    // The bundle pads for the status bar and home indicator itself
                    // (viewport-fit=cover), so it draws edge to edge. The keyboard
                    // still resizes the view.
                    .ignoresSafeArea(.container)
                    #endif
            } else {
                ContentUnavailableView("Shared interface missing", systemImage: "exclamationmark.triangle",
                    description: Text("Build SharedUI before packaging. Advanced native controls remain available; enforcement has not been changed."))
                Button("Advanced native controls") { session.showAdvancedControls = true }
                    .padding()
            }
        }
        // Matches the bundle's --bg, so nothing flashes before the page paints.
        .background(canvas.ignoresSafeArea())
        .preferredColorScheme(appearanceTheme == "dark" ? .dark : .light)
        .sheet(isPresented: $session.showAdvancedControls) {
            #if os(macOS)
            // The Mac view brings its own header with Close and the actions a
            // window toolbar would hold. It may be narrower than the main window.
            MacContentView(embedded: true, onClose: { session.showAdvancedControls = false })
                .environmentObject(session.model)
                .frame(minWidth: 1040, idealWidth: 1240, minHeight: 620, idealHeight: 760)
            #else
            VStack(spacing: 0) {
                HStack {
                    Text("Advanced native controls").font(.headline)
                    Spacer()
                    Button("Close") { session.showAdvancedControls = false }
                }
                .padding()
                ContentView().environmentObject(session.model)
            }
            #endif
        }
        .sheet(isPresented: Binding(get: { session.nativePanel != nil }, set: { if !$0 { session.nativePanel = nil } })) {
            #if os(macOS)
            VStack {
                // The lockdown and diagnostics sheets carry their own Close button.
                if session.nativePanel != "startLockdown" && session.nativePanel != "diagnostics" {
                    HStack { Spacer(); Button("Close") { session.nativePanel = nil }.padding() }
                }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red).padding().accessibilityLabel("Action needed: \(error)") }
                nativePanel
            }
            .frame(minWidth: 900, minHeight: 650)
            #else
            // Each iOS panel carries its own navigation bar, dismiss button and
            // error reporting; a second "Close" row above it only adds noise.
            nativePanel
            #endif
        }
        #if os(iOS)
        .sheet(isPresented: $session.pickingApplications, onDismiss: { session.finishPicker(accept: false) }) {
            NavigationStack {
                FamilyActivityPicker(selection: $session.selection)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { session.finishPicker(accept: false) } }
                        ToolbarItem(placement: .confirmationAction) { Button("Use selection") { session.finishPicker(accept: true) } }
                    }
            }
        }
        .onDisappear { session.finishPicker(accept: false) }
        #endif
    }

    private var canvas: Color {
        appearanceTheme == "dark"
            ? Color(red: 9 / 255, green: 11 / 255, blue: 11 / 255)
            : Color(red: 244 / 255, green: 241 / 255, blue: 233 / 255)
    }

    @ViewBuilder private var nativePanel: some View {
        #if os(macOS)
        switch session.nativePanel {
        case "startLockdown": MacLockdownSessionSheet(model: session.model)
        case "diagnostics": MacDiagnosticsSheet(model: session.model)
        case "createRetreat":
            MacRetreatComposerView(baselineGroups: session.model.baseline.blockingGroups,
                retreats: [], initialRetreat: nil, onOpenRetreat: { _ in }) { value in
                    session.model.errorMessage = nil
                    session.model.saveRetreat(name: value.name, goal: value.goal, plannedStart: value.plannedStart,
                        plannedEnd: value.plannedEnd, sourceBlockingGroups: value.blockingGroups,
                        modificationPolicy: value.modificationPolicy, startImmediately: value.startImmediately)
                    if session.model.errorMessage == nil { session.nativePanel = nil }
                }
        default: MacContentView().environmentObject(session.model)
        }
        #else
        switch session.nativePanel {
        case "startLockdown": IOSTimedLockdownView().environmentObject(session.model)
        case "diagnostics":
            NavigationStack {
                IOSDiagnosticsView()
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { session.nativePanel = nil } } }
                    .iosModelErrorAlert()
            }
            .environmentObject(session.model)
        case "createRetreat": IOSRetreatEditor(initialRetreat: CloudRetreat(), isNew: true).environmentObject(session.model)
        // Screen Time access, iCloud and hardening live in the native settings.
        case "settings": SettingsView().environmentObject(session.model)
        default:
            VStack(spacing: 0) {
                HStack { Spacer(); Button("Close") { session.nativePanel = nil }.padding() }
                ContentView().environmentObject(session.model)
            }
        }
        #endif
    }
}
