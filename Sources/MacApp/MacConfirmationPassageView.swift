import SwiftUI

/// A ScrollView has no intrinsic content height. In a content-sized sheet a
/// maximum alone lets its viewport collapse to zero, hiding the passage.
struct MacConfirmationPassageView: View {
    let passage: String
    var height: CGFloat = 150

    var body: some View {
        ScrollView {
            Text(passage)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.disabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(height: height)
        .background(MacBrutalPalette.raisedSurface)
        .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
        .accessibilityIdentifier("confirmation-passage")
        .help("Type directly. Paste, drag-and-drop, and bulk text insertion are disabled.")
    }
}
