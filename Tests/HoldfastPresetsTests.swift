import XCTest
#if !DESKTOP_HOSTLESS_TESTS
@testable import Holdfast
#endif

final class HoldfastPresetsTests: XCTestCase {
    func testInstallingAPresetAddsEnabledLockedGroupAndReusesActivityGroups() throws {
        var document = CloudPreferencesDocument()
        let work = try XCTUnwrap(HoldfastPresets.blockingPresets.first { $0.id == "work-hours" })
        let evenings = try XCTUnwrap(HoldfastPresets.blockingPresets.first { $0.id == "evenings-off" })

        let workID = HoldfastPresets.install(work, into: &document)
        let activityCount = document.activityGroups.count
        XCTAssertEqual(activityCount, work.activityPresetIDs.count)
        _ = HoldfastPresets.install(evenings, into: &document)
        XCTAssertEqual(document.activityGroups.count, activityCount,
                       "Evenings off reuses the Social, Video and News groups by name")

        let group = try XCTUnwrap(document.baseline.blockingGroups.first { $0.id == workID })
        XCTAssertTrue(group.isEnabled)
        XCTAssertEqual(group.modificationPolicy.severity, "passageOnly")
        XCTAssertEqual(document.rules.count, 2, "Presets compile into enforceable rules")
        XCTAssertTrue(document.rules.first { $0.id == workID }?.domains.contains { $0.domain == "reddit.com" } ?? false)
    }

    func testTunnelPresetUsesVendorFamiliesThatMatchHelpers() {
        let tunnels = HoldfastPresets.activityPresets.first { $0.id == "tunnels" }
        XCTAssertTrue(tunnels?.macApplicationIdentifiers.allSatisfy { $0.hasSuffix(".*") } ?? false)
        let rule = DesktopEnforcementRule(
            id: UUID(), name: "Tunnels", isEnabled: true, enforcementMode: .blockList, windows: [],
            domains: [], macApplicationIdentifiers: ["com.nordvpn.*"], windowsExecutablePaths: [],
            windowsPublisherRules: [],
            lockdown: DesktopLockdownPolicy(severity: "delayed", unlockDelayDays: 1, passageWordCount: 40,
                confirmationWindowHours: 24, editWindowHours: 24, allowsTimeExtensions: false,
                maximumTimeExtensionHours: 1))
        XCTAssertTrue(rule.matchesApplication("com.nordvpn.macos.PacketTunnel"))
        XCTAssertFalse(rule.matchesApplication("com.nordvpnfake.app"))
        XCTAssertFalse(rule.matchesApplication(""))
    }

    func testReflectionNeedsFourWordsAndIsBounded() {
        XCTAssertFalse(ReflectionPrompt.isSufficient("just a sec"))
        XCTAssertTrue(ReflectionPrompt.isSufficient("reply to Sam's message"))
        XCTAssertNil(ReflectionPrompt.normalized("   no  "))
        let long = String(repeating: "word ", count: 200)
        XCTAssertEqual(ReflectionPrompt.normalized(long)?.count, ReflectionPrompt.maximumCharacters)
        let seed = UUID()
        XCTAssertEqual(ReflectionPrompt.prompt(for: seed), ReflectionPrompt.prompt(for: seed))
    }
}
