import FamilyControls
import Foundation

extension AppModel {
    /// A full interpretable snapshot of this device's state.
    ///
    /// Built on demand rather than accumulated, because the questions worth
    /// asking are about what is true right now: which shields are applied, which
    /// monitors iOS is actually holding, and whether those two agree with the
    /// schedule.
    func makeDiagnosticReport(
        redaction: HoldfastDiagnosticRedaction,
        now: Date = Date()
    ) -> HoldfastDiagnosticReport {
        IOSDiagnosticsReport.build(
            document: cloudDocument,
            rules: rules,
            authorizationStatus: authorizationStatus,
            cloudSyncStatus: cloudSyncStatus,
            pendingCloudRuleIDs: pendingCloudRuleIDs,
            lockdownConfiguration: lockdownConfiguration,
            unlockPhase: unlockPhase,
            ruleUnlockPhases: ruleUnlockPhases,
            retreatUnlockPhases: retreatUnlockPhases,
            redaction: redaction,
            now: now
        )
    }

    /// Writes the report as a readable text file and a machine-readable JSON
    /// file, and returns both. The text file is what a person opens; the JSON is
    /// what a diff or a script reads.
    func writeDiagnosticReport(_ report: HoldfastDiagnosticReport) throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let textURL = directory.appendingPathComponent("\(report.suggestedFileName).txt")
        let jsonURL = directory.appendingPathComponent("\(report.suggestedFileName).json")
        try Data(report.renderedText().utf8).write(to: textURL, options: .atomic)
        try report.jsonData().write(to: jsonURL, options: .atomic)
        return [textURL, jsonURL]
    }

    /// Removes previously exported reports. They contain a description of the
    /// user's rules, so they should not accumulate in a temporary directory.
    func discardExportedDiagnostics() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }
}

extension AppModel {
    /// Clears every Screen Time restriction this app holds, including stores it
    /// can no longer name.
    ///
    /// `ManagedSettings` offers no way to enumerate stores, so a shield written
    /// under an identity the document has since forgotten cannot be reached by
    /// name at all. Revoking Family Controls authorization discards every store
    /// the app owns, which is the only reliable way to clear one. Authorization
    /// is then requested again and the live schedule is rebuilt from scratch.
    ///
    /// This removes all protection for as long as it takes to re-authorize, so
    /// it is deliberately a recovery action rather than an ordinary control.
    func resetAllScreenTimeRestrictions() async -> String {
        let center = AuthorizationCenter.shared
        do {
            try await withCheckedThrowingContinuation { continuation in
                center.revokeAuthorization { result in
                    continuation.resume(with: result)
                }
            }
        } catch {
            return "Screen Time access could not be revoked: \(error.localizedDescription)"
        }

        // The ledger describes stores that no longer exist.
        SharedConfiguration.shieldedWindowStoreNames = []

        do {
            try await center.requestAuthorization(for: .individual)
        } catch {
            refreshAuthorizationAndEnforcement()
            return "Restrictions were cleared, but Screen Time access was not granted again: \(error.localizedDescription). Grant it to resume enforcement."
        }

        refreshAuthorizationAndEnforcement()
        return "All Screen Time restrictions were cleared and the current schedule was reapplied. "
            + "Confirm a rule still blocks during its next window: Apple's selection tokens are tied to the authorisation that issued them."
    }
}
