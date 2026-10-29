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
            } else {
                ContentUnavailableView("Shared interface missing", systemImage: "exclamationmark.triangle",
                    description: Text("Build SharedUI before packaging. Advanced native controls remain available; enforcement has not been changed."))
                Button("Advanced native controls") { session.showAdvancedControls = true }
                    .padding()
            }
        }
        .preferredColorScheme(appearanceTheme == "dark" ? .dark : .light)
        .sheet(isPresented: $session.showAdvancedControls) {
            VStack {
                HStack { Spacer(); Button("Close") { session.showAdvancedControls = false }.padding() }
                #if os(macOS)
                MacContentView().environmentObject(session.model).frame(minWidth: 1240, minHeight: 700)
                #else
                ContentView().environmentObject(session.model)
                #endif
            }
        }
        .sheet(isPresented: Binding(get: { session.nativePanel != nil }, set: { if !$0 { session.nativePanel = nil } })) {
            VStack {
                HStack { Spacer(); Button("Close") { session.nativePanel = nil }.padding() }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red).padding().accessibilityLabel("Action needed: \(error)") }
                nativePanel
            }
            #if os(macOS)
            .frame(minWidth: 900, minHeight: 650)
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
        case "diagnostics": NavigationStack { IOSDiagnosticsView().environmentObject(session.model) }
        case "createRetreat": IOSRetreatEditor(initialRetreat: CloudRetreat(), isNew: true).environmentObject(session.model)
        default: ContentView().environmentObject(session.model)
        }
        #endif
    }
}
