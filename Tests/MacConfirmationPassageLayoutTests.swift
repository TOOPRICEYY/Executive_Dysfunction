#if os(macOS)
import AppKit
import SwiftUI
import XCTest

final class MacConfirmationPassageLayoutTests: XCTestCase {
    @MainActor
    func testBlockingTargetsEditorFitsCompactMacPanel() throws {
        let targets = CloudBlockingTargets(domains: [
            .init(domain: "example.com", category: "other", source: "user"),
            .init(domain: "example.org", category: "other", source: "user")
        ], websiteCategories: ["other"], macApplicationIdentifiers: ["com.apple.Safari"])
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: MacBlockingTargetsEditor(targets: .constant(targets))
                .padding(24).frame(width: 680).background(MacBrutalPalette.surface)
                .environment(\.colorScheme, scheme))
            let size = host.fittingSize
            XCTAssertLessThan(size.height, 650, "Routine targets should fit without a wall of advanced settings")
            XCTAssertGreaterThan(size.height, 250)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "blocking-targets-\(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.close()
        }
    }

    @MainActor
    func testPassageInputRejectsBulkInsertionAndAllowsTypingAndDeletion() {
        let coordinator = MacPassageInput(text: .constant("")).makeCoordinator()
        let editor = DirectTypingTextView()
        XCTAssertFalse(coordinator.textView(editor, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: "pasted passage"))
        XCTAssertTrue(coordinator.textView(editor, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: "a"))
        XCTAssertTrue(coordinator.textView(editor, shouldChangeTextIn: NSRange(location: 0, length: 3), replacementString: ""))
        editor.insertText("bulk replacement", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.string, "")
        editor.insertText("a", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.string, "a")
    }

    @MainActor
    func testLockdownStatusShowsActiveAndHidesExpiredSessions() {
        let rule = CloudRulePreference(name: "Social feeds")
        let session = DesktopLockdownSessionGate.makeSession(
            ruleIDs: [rule.id], duration: 3_600,
            lockdown: DesktopLockdownPolicy(severity: "passageOnly", unlockDelayDays: 0,
                passageWordCount: 40, confirmationWindowHours: 24, editWindowHours: 1,
                allowsTimeExtensions: false, maximumTimeExtensionHours: 0)
        )
        for scheme in [ColorScheme.light, .dark] {
            let active = NSHostingView(rootView: MacLockdownStatusView(
                sessions: [session], rules: [rule], onManage: {}
            ).frame(width: 600).environment(\.colorScheme, scheme))
            XCTAssertGreaterThan(active.fittingSize.height, 100)
            var expired = session
            expired.endsAt = Date().addingTimeInterval(-60)
            let inactive = NSHostingView(rootView: MacLockdownStatusView(
                sessions: [expired], rules: [rule], onManage: {}
            ).frame(width: 600))
            XCTAssertLessThan(inactive.fittingSize.height, 1)
            let empty = NSHostingView(rootView: MacLockdownStatusView(
                sessions: [], rules: [], onManage: {}
            ).frame(width: 600))
            XCTAssertLessThan(empty.fittingSize.height, 1)
        }
    }

    @MainActor
    func testPassageRemainsVisibleInContentSizedSheets() throws {
        for scheme in [ColorScheme.light, .dark] {
            for words in [20, 300] {
                let passage = DesktopRemovalGate.passage(wordCount: words, seed: UUID())
                let content = VStack(alignment: .leading, spacing: 14) {
                    Text("Disable web blocking").font(.title3.weight(.semibold))
                    MacConfirmationPassageView(passage: passage)
                    TextField("Confirmation passage", text: .constant(""))
                        .macBrutalTextField()
                    Button("Cancel") {}
                }
                .padding(20)
                .frame(width: 540)
                .macBrutalSheet()
                .environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: content)
                let size = host.fittingSize
                XCTAssertGreaterThanOrEqual(size.height, 230, "Passage viewport must contribute its full height")
                XCTAssertEqual(size.width, 540, accuracy: 1)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "passage-\(scheme)-\(words)-words"
                attachment.lifetime = .keepAlways
                add(attachment)
                window.close()
            }
        }
    }
}
#endif
