import Darwin
import Foundation

/// A read-only, bounded diagnostics surface for the shell smoke-test harness.
/// Running the signed app executable with this flag exits before constructing
/// `MacAppModel` or touching NetworkExtension.
enum MacEnforcementSafetyStateReporter {
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
