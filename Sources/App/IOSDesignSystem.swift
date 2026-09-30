import SwiftUI
import UIKit

enum IOSInterfaceTheme: String, CaseIterable, Identifiable {
    static let storageKey = "executiveDysfunction.interfaceTheme"
    case light, dark

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
}

enum IOSHighlightColor: String, CaseIterable, Identifiable {
    static let storageKey = "executiveDysfunction.highlightColor"
    case themeDefault, signalYellow, phosphorGreen, electricBlue
    case warningOrange, hotMagenta, terminalViolet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .themeDefault: "THEME DEFAULT"
        case .signalYellow: "SIGNAL YELLOW"
        case .phosphorGreen: "PHOSPHOR GREEN"
        case .electricBlue: "ELECTRIC BLUE"
        case .warningOrange: "WARNING ORANGE"
        case .hotMagenta: "HOT MAGENTA"
        case .terminalViolet: "TERMINAL VIOLET"
        }
    }

    func uiColor(isDark: Bool) -> UIColor {
        switch self {
        case .themeDefault:
            isDark
                ? UIColor(red: 0.28, green: 0.95, blue: 0.16, alpha: 1)
                : UIColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1)
        case .signalYellow: UIColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1)
        case .phosphorGreen: UIColor(red: 0.28, green: 0.95, blue: 0.16, alpha: 1)
        case .electricBlue: UIColor(red: 0.08, green: 0.46, blue: 1.0, alpha: 1)
        case .warningOrange: UIColor(red: 1.0, green: 0.48, blue: 0.0, alpha: 1)
        case .hotMagenta: UIColor(red: 1.0, green: 0.24, blue: 0.64, alpha: 1)
        case .terminalViolet: UIColor(red: 0.66, green: 0.49, blue: 1.0, alpha: 1)
        }
    }

    /// Bright fills work with black text, but the same yellow/green used as
    /// text on the light canvas is unreadable. Keep the accent hue and use a
    /// darker ink variant for native controls only.
    func controlColor(isDark: Bool) -> UIColor {
        guard !isDark else { return uiColor(isDark: true) }
        return switch self {
        case .themeDefault, .signalYellow: UIColor(red: 0.46, green: 0.36, blue: 0, alpha: 1)
        case .phosphorGreen: UIColor(red: 0.12, green: 0.40, blue: 0.03, alpha: 1)
        case .electricBlue: UIColor(red: 0.04, green: 0.33, blue: 0.78, alpha: 1)
        case .warningOrange: UIColor(red: 0.68, green: 0.28, blue: 0, alpha: 1)
        case .hotMagenta: UIColor(red: 0.73, green: 0.08, blue: 0.40, alpha: 1)
        case .terminalViolet: UIColor(red: 0.42, green: 0.22, blue: 0.72, alpha: 1)
        }
    }

    static var current: IOSHighlightColor {
        guard let raw = UserDefaults.standard.string(forKey: storageKey) else {
            return .themeDefault
        }
        return IOSHighlightColor(rawValue: raw) ?? .themeDefault
    }
}

enum IOSBrutalPalette {
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.035, green: 0.045, blue: 0.045, alpha: 1)
            : UIColor(red: 0.955, green: 0.945, blue: 0.915, alpha: 1)
    })
    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.065, green: 0.075, blue: 0.075, alpha: 1)
            : UIColor(red: 0.995, green: 0.99, blue: 0.975, alpha: 1)
    })
    static let raised = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.105, green: 0.115, blue: 0.115, alpha: 1)
            : UIColor(red: 0.91, green: 0.90, blue: 0.87, alpha: 1)
    })
    static let rule = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.43, green: 0.46, blue: 0.45, alpha: 1)
            : UIColor(red: 0.12, green: 0.12, blue: 0.11, alpha: 1)
    })
    static let signal = Color(uiColor: UIColor { traits in
        IOSHighlightColor.current.uiColor(isDark: traits.userInterfaceStyle == .dark)
    })
    static let controlAccent = Color(uiColor: UIColor { traits in
        IOSHighlightColor.current.controlColor(isDark: traits.userInterfaceStyle == .dark)
    })
}

enum IOSBrutalButtonEmphasis { case primary, secondary, danger }

struct IOSBrutalButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var emphasis: IOSBrutalButtonEmphasis = .secondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.callout, design: .default, weight: .bold))
            
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .foregroundStyle(emphasis == .primary ? Color.black : Color.primary)
            .background(background(configuration.isPressed))
            .overlay {
                Rectangle().stroke(
                    emphasis == .danger ? Color.red : IOSBrutalPalette.rule,
                    lineWidth: emphasis == .primary ? 2 : 1
                )
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
    }

    private func background(_ pressed: Bool) -> Color {
        if emphasis == .primary {
            return IOSBrutalPalette.signal.opacity(pressed ? 0.7 : 1)
        }
        return pressed ? IOSBrutalPalette.raised : IOSBrutalPalette.surface
    }
}

struct IOSBrutalCard<Content: View>: View {
    let backgroundColor: Color
    let content: Content

    init(
        background: Color = IOSBrutalPalette.surface,
        @ViewBuilder content: () -> Content
    ) {
        backgroundColor = background
        self.content = content()
    }

    var body: some View {
        // The card has to stack its children itself. Applying these modifiers
        // straight to a multi-statement ViewBuilder result applies them to each
        // child individually, which renders one bordered box per child instead
        // of one card around the group.
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
        .overlay { Rectangle().stroke(IOSBrutalPalette.rule, lineWidth: 1) }
    }
}

private struct IOSModelErrorAlert: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @State private var message: String?

    func body(content: Content) -> some View {
        content
            .onAppear { claim() }
            .onChange(of: model.errorMessage) { _, _ in claim() }
            .alert("Action needed", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("OK", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "Unknown error")
            }
    }

    /// The message moves out of the model and into this screen. The workspace
    /// root binds the same property, and two live alert bindings over one value
    /// leave the covered root's alert to win and nothing on screen.
    private func claim() {
        guard let pending = model.errorMessage else { return }
        message = pending
        model.errorMessage = nil
    }
}

extension View {
    /// Editors are presented as sheets, and an alert attached to the workspace
    /// root cannot appear over a sheet. Without this, a save the model rejects
    /// -- a lock that refuses a weaker edit, a Retreat with no Blocking Group --
    /// fails in silence: the button does nothing and the sheet stays open.
    func iosModelErrorAlert() -> some View {
        modifier(IOSModelErrorAlert())
    }

    func iosBrutalField() -> some View {
        self
            .font(.system(.body, design: .default))
            .padding(11)
            .background(IOSBrutalPalette.surface)
            .overlay { Rectangle().stroke(IOSBrutalPalette.rule, lineWidth: 1) }
    }
}
