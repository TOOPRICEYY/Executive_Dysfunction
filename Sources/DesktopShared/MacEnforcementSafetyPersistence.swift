import Foundation

/// One coherent, cross-process receipt for a successful same-boot reset.
///
/// The receipt grants no authority to enable Network Extension preferences. It
/// only records that the app proved the preference absent and connectivity
/// healthy while disabled intent remained set.
struct MacEnforcementSameBootResetReceipt: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var attemptIdentifier: String
    var bootSessionIdentifier: String
    var completedAtEpochSeconds: TimeInterval

    init(
        attemptIdentifier: String,
        bootSessionIdentifier: String,
        completedAt: Date
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.attemptIdentifier = attemptIdentifier
        self.bootSessionIdentifier = bootSessionIdentifier
        completedAtEpochSeconds = completedAt.timeIntervalSince1970
    }

    var isWellFormed: Bool {
        schemaVersion == Self.currentSchemaVersion
            && !attemptIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !bootSessionIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && completedAtEpochSeconds.isFinite
            && completedAtEpochSeconds > 0
    }
}

/// Read-only snapshot printed by the signed app's safety-state reporter. Shell
/// diagnostics invoke that reporter instead of reading a sandbox container or
/// waiting indefinitely on `defaults`/cfprefsd.
struct MacEnforcementSafetyStateSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = Self.currentSchemaVersion
    var blockingDisabled: Bool
    var activationSafetyLatchSet: Bool
    var activationSafetyBootSessionIdentifier: String?
    var activationSafetyReason: String?
    var activationSafetyTriggeredAt: Date?
    var sameBootResetReceipt: MacEnforcementSameBootResetReceipt?
}

enum MacEnforcementSafetyPersistence {
    enum PersistenceError: Error {
        case malformedReceipt
    }

    static let blockingDisabledKey = "desktop-enforcement.blocking-disabled"
    static let activationSafetyBootSessionKey = "desktop-enforcement.activation-safety.boot-session"
    static let activationSafetyBootTimeKey = "desktop-enforcement.activation-safety.boot-time"
    static let activationSafetyTriggeredAtKey = "desktop-enforcement.activation-safety.triggered-at"
    static let activationSafetyReasonKey = "desktop-enforcement.activation-safety.reason"
    static let sameBootResetReceiptDataKey = "desktop-enforcement.same-boot-reset.receipt-v1"

    static func encode(_ receipt: MacEnforcementSameBootResetReceipt) throws -> Data {
        guard receipt.isWellFormed else {
            throw PersistenceError.malformedReceipt
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(receipt)
    }

    static func decodeReceipt(from data: Data?) -> MacEnforcementSameBootResetReceipt? {
        guard let data,
              let receipt = try? JSONDecoder().decode(
                  MacEnforcementSameBootResetReceipt.self,
                  from: data
              ), receipt.isWellFormed else {
            return nil
        }
        return receipt
    }

    static func persist(
        _ receipt: MacEnforcementSameBootResetReceipt,
        defaults: UserDefaults
    ) throws {
        defaults.set(try encode(receipt), forKey: sameBootResetReceiptDataKey)
    }

    static func snapshot(defaults: UserDefaults) -> MacEnforcementSafetyStateSnapshot {
        let activationKeys: [String] = [
            activationSafetyBootSessionKey,
            activationSafetyBootTimeKey,
            activationSafetyTriggeredAtKey,
            activationSafetyReasonKey,
        ]
        return MacEnforcementSafetyStateSnapshot(
            blockingDisabled: defaults.bool(forKey: blockingDisabledKey),
            activationSafetyLatchSet: activationKeys.contains {
                defaults.object(forKey: $0) != nil
            },
            activationSafetyBootSessionIdentifier: defaults.string(
                forKey: activationSafetyBootSessionKey
            ),
            activationSafetyReason: defaults.string(forKey: activationSafetyReasonKey),
            activationSafetyTriggeredAt: (defaults.object(forKey: activationSafetyTriggeredAtKey) as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) },
            sameBootResetReceipt: decodeReceipt(
                from: defaults.data(forKey: sameBootResetReceiptDataKey)
            )
        )
    }
}
