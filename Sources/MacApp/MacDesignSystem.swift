import AppKit
import SwiftUI

enum MacInterfaceTheme: String, CaseIterable, Identifiable {
    static let storageKey = "executiveDysfunction.interfaceTheme"

    case light
    case dark

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
}

enum MacHighlightColor: String, CaseIterable, Identifiable {
    static let storageKey = "executiveDysfunction.highlightColor"
    static let defaultValue = MacHighlightColor.themeDefault

    case themeDefault
    case signalYellow
    case phosphorGreen
    case electricBlue
    case warningOrange
    case hotMagenta
    case terminalViolet

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

    func nsColor(isDark: Bool) -> NSColor {
        switch self {
        case .themeDefault:
            isDark
                ? NSColor(srgbRed: 0.28, green: 0.95, blue: 0.16, alpha: 1)
                : NSColor(srgbRed: 1.0, green: 0.84, blue: 0.0, alpha: 1)
        case .signalYellow: NSColor(srgbRed: 1.0, green: 0.84, blue: 0.0, alpha: 1)
        case .phosphorGreen: NSColor(srgbRed: 0.28, green: 0.95, blue: 0.16, alpha: 1)
        case .electricBlue: NSColor(srgbRed: 0.08, green: 0.46, blue: 1.0, alpha: 1)
        case .warningOrange: NSColor(srgbRed: 1.0, green: 0.48, blue: 0.0, alpha: 1)
        case .hotMagenta: NSColor(srgbRed: 1.0, green: 0.24, blue: 0.64, alpha: 1)
        case .terminalViolet: NSColor(srgbRed: 0.66, green: 0.49, blue: 1.0, alpha: 1)
        }
    }

    var color: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return nsColor(isDark: isDark)
        })
    }

    static var current: MacHighlightColor {
        guard let rawValue = UserDefaults.standard.string(forKey: storageKey) else {
            return defaultValue
        }
        return MacHighlightColor(rawValue: rawValue) ?? defaultValue
    }
}

enum MacBrutalPalette {
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        isDark(appearance)
            ? NSColor(srgbRed: 0.035, green: 0.045, blue: 0.045, alpha: 1)
            : NSColor(srgbRed: 0.955, green: 0.945, blue: 0.915, alpha: 1)
    })

    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        isDark(appearance)
            ? NSColor(srgbRed: 0.065, green: 0.075, blue: 0.075, alpha: 1)
            : NSColor(srgbRed: 0.995, green: 0.99, blue: 0.975, alpha: 1)
    })

    static let raisedSurface = Color(nsColor: NSColor(name: nil) { appearance in
        isDark(appearance)
            ? NSColor(srgbRed: 0.105, green: 0.115, blue: 0.115, alpha: 1)
            : NSColor(srgbRed: 0.91, green: 0.90, blue: 0.87, alpha: 1)
    })

    static let rule = Color(nsColor: NSColor(name: nil) { appearance in
        isDark(appearance)
            ? NSColor(srgbRed: 0.43, green: 0.46, blue: 0.45, alpha: 1)
            : NSColor(srgbRed: 0.12, green: 0.12, blue: 0.11, alpha: 1)
    })

    static let signal = Color(nsColor: NSColor(name: nil) { appearance in
        MacHighlightColor.current.nsColor(isDark: isDark(appearance))
    })

    // Bright fills need a darker ink counterpart on the light canvas.
    static let controlAccent = Color(nsColor: NSColor(name: nil) { appearance in
        let color = MacHighlightColor.current.nsColor(isDark: isDark(appearance))
        return isDark(appearance) ? color : (color.blended(withFraction: 0.5, of: .black) ?? color)
    })

    // Allowance cells, selected navigation, primary actions, focus rings, and
    // status accents intentionally share one user-configurable highlight token.
    static let scheduleSignal = signal

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

enum MacBrutalButtonEmphasis {
    case primary
    case secondary
    case danger
}

struct MacBrutalButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let emphasis: MacBrutalButtonEmphasis

    init(_ emphasis: MacBrutalButtonEmphasis = .secondary) {
        self.emphasis = emphasis
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.callout, design: .default, weight: .semibold))
            
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 38)
            .foregroundStyle(foregroundColor)
            .background(configuration.isPressed ? pressedBackground : background)
            .overlay {
                Rectangle()
                    .stroke(borderColor, lineWidth: emphasis == .primary ? 2 : 1)
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
    }

    private var foregroundColor: Color {
        switch emphasis {
        case .primary: Color.black
        case .secondary: .primary
        case .danger: .red
        }
    }

    private var background: Color {
        emphasis == .primary ? MacBrutalPalette.signal : MacBrutalPalette.surface
    }

    private var pressedBackground: Color {
        emphasis == .primary
            ? MacBrutalPalette.signal.opacity(0.72)
            : MacBrutalPalette.raisedSurface
    }

    private var borderColor: Color {
        emphasis == .danger ? Color.red : MacBrutalPalette.rule
    }
}

struct MacBrutalCheckboxIndicator: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(isOn ? MacBrutalPalette.signal : MacBrutalPalette.surface)
            if isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color.black)
            }
        }
        .frame(width: 19, height: 19)
        .overlay {
            Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1.5)
        }
    }
}

struct MacBrutalCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                MacBrutalCheckboxIndicator(isOn: configuration.isOn)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

struct MacThemeSwitch: View {
    @AppStorage(MacInterfaceTheme.storageKey) private var storedTheme = MacInterfaceTheme.light.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("THEME")
                .font(.system(.caption, design: .default, weight: .bold))
                .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                ForEach(MacInterfaceTheme.allCases) { theme in
                    Button(theme.label) {
                        storedTheme = theme.rawValue
                    }
                    .buttonStyle(.plain)
                    .font(.system(.caption, design: .default, weight: .bold))
                    .foregroundStyle(storedTheme == theme.rawValue ? Color.black : Color.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(storedTheme == theme.rawValue ? MacBrutalPalette.signal : MacBrutalPalette.surface)
                    .overlay {
                        Rectangle()
                            .stroke(storedTheme == theme.rawValue ? MacBrutalPalette.signal : MacBrutalPalette.rule, lineWidth: storedTheme == theme.rawValue ? 2 : 1)
                    }
                }
            }
        }
    }
}

private struct MacBrutalTextFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(.body, design: .default))
            .padding(10)
            .background(MacBrutalPalette.surface)
            .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
    }
}

private struct MacBrutalSheetModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(.body, design: .default))
            .background(MacBrutalPalette.canvas)
            .tint(MacBrutalPalette.controlAccent)
    }
}

extension View {
    func macBrutalTextField() -> some View {
        modifier(MacBrutalTextFieldModifier())
    }

    func macBrutalSheet() -> some View {
        modifier(MacBrutalSheetModifier())
    }
}
