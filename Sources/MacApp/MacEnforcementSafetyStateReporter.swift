import Darwin
import Foundation
import NetworkExtension

/// A read-only, bounded diagnostics surface for the shell smoke-test harness.
/// Running the signed app executable with this flag exits before constructing
/// `MacAppModel` or touching NetworkExtension.
enum MacEnforcementSafetyStateReporter {
    /// Reads the installed preference without constructing the app model or
    /// requesting activation. IP coverage is needed to audit selective bypasses.
    static func reportFilterPreferencesAndExit() -> Never {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { Darwin.exit(70) }
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { error in
            var report: [String: Any] = ["enabled": manager.isEnabled]
            if let error { report["error"] = error.localizedDescription }
            if let configuration = manager.providerConfiguration {
                report["filterSockets"] = configuration.filterSockets
                report["filterPackets"] = configuration.filterPackets
                if let revision = DesktopPolicyConfigurationTransport.revision(from: configuration.vendorConfiguration) {
                    report["revision"] = revision
                }
                if let prepared = DesktopPolicyConfigurationTransport.preparedRetryGuards(from: configuration.vendorConfiguration) {
                    report["preparedAddresses"] = prepared.addressesByDomainSuffix
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                try? FileHandle.standardOutput.write(contentsOf: data)
            }
            Darwin.exit(error == nil ? 0 : 70)
        }
        RunLoop.main.run()
        Darwin.exit(70)
    }
    static let argument = "--report-enforcement-safety-state"

    static func reportAndExit(defaults: UserDefaults = .standard) -> Never {
        do {
            let snapshot = MacEnforcementSafetyPersistence.snapshot(defaults: defaults)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(snapshot)
            data.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: data)
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            let message = "enforcement-safety-state-report-failed: \(error)\n"
            if let data = message.data(using: .utf8) {
                try? FileHandle.standardError.write(contentsOf: data)
            }
            Darwin.exit(70)
        }
    }
}
