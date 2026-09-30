import AppKit
import SwiftUI

/// Deliberate-typing friction, not a security boundary against automation/OCR.
struct MacPassageInput: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let editor = DirectTypingTextView()
        editor.isRichText = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.autoresizingMask = [.width]
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel("Confirmation passage — type directly; paste is disabled")
        editor.delegate = context.coordinator
        editor.string = text
        scroll.documentView = editor
        editor.unregisterDraggedTypes()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let editor = scroll.documentView as? NSTextView, editor.string != text {
            editor.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacPassageInput
        init(_ parent: MacPassageInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { parent.text = view.string }
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            (replacementString?.count ?? 0) <= 1
        }
    }
}

final class DirectTypingTextView: NSTextView {
    override func paste(_ sender: Any?) { NSSound.beep() }
    override func pasteAsPlainText(_ sender: Any?) { NSSound.beep() }
    override func pasteAsRichText(_ sender: Any?) { NSSound.beep() }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let value = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        guard value.count <= 1 else { NSSound.beep(); return }
        super.insertText(insertString, replacementRange: replacementRange)
    }
}
