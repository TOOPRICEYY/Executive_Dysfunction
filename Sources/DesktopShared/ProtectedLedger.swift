import Foundation
import os
import Security

/// Mac lock state kept where the device owner cannot edit it by hand.
///
/// Items live in the data-protection Keychain (`kSecUseDataProtectionKeychain`),
/// which is scoped by the app's signed `keychain-access-groups` entitlement.
/// Unlike the file-based login keychain or a preferences plist, neither
/// `defaults`, `plutil` nor Keychain Access can read or rewrite these items
/// without a binary signed by this team. That does not stop an administrator
/// who rebuilds the app (see Docs/MacAdministratorHardening.md, Tier 4); it
/// turns a one-minute plist edit into a rebuild.
///
/// If the data-protection Keychain is unavailable (for example an unsigned
/// development build without the entitlement), the ledger falls back to the
/// supplied defaults and logs a fault, so enforcement keeps working exactly as
/// it did before rather than failing to record grants.
final class KeychainProtectedLedger: KeyValueLedger, @unchecked Sendable {
    private let service: String
    private let fallback: UserDefaults
    private let lock = NSLock()
    private var cache: [String: Data?] = [:]
    private var usesFallback = false
    private let logger = Logger(
        subsystem: "com.GabrielPrice.ExecutiveDysfunction",
        category: "protected-ledger"
    )

    init(
        service: String = "com.GabrielPrice.ExecutiveDysfunction.lock-ledger.v1",
        fallback: UserDefaults = .standard
    ) {
        self.service = service
        self.fallback = fallback
    }

    func data(forKey defaultName: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if usesFallback { return fallback.data(forKey: defaultName) }
        if let cached = cache[defaultName] { return cached }

        var query = baseQuery(defaultName)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            let data = item as? Data
            cache[defaultName] = .some(data)
            return data
        case errSecItemNotFound:
            cache[defaultName] = .some(nil)
            return nil
        default:
            if switchToFallbackIfUnavailable(status) {
                return fallback.data(forKey: defaultName)
            }
            logger.error("ledger_read_failed key=\(defaultName, privacy: .public) status=\(status, privacy: .public)")
            // Unreadable state is treated as absent: no pause, no unlock progress.
            return nil
        }
    }

    func set(_ value: Any?, forKey defaultName: String) {
        guard let data = value as? Data else {
            removeObject(forKey: defaultName)
            return
        }
        lock.lock()
        defer { lock.unlock() }
        if usesFallback {
            fallback.set(data, forKey: defaultName)
            return
        }
        var add = baseQuery(defaultName)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(
                baseQuery(defaultName) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        }
        if status == errSecSuccess {
            cache[defaultName] = data
        } else if switchToFallbackIfUnavailable(status) {
            fallback.set(data, forKey: defaultName)
        } else {
            cache[defaultName] = nil
            logger.error("ledger_write_failed key=\(defaultName, privacy: .public) status=\(status, privacy: .public)")
        }
    }

    func removeObject(forKey defaultName: String) {
        lock.lock()
        defer { lock.unlock() }
        if usesFallback {
            fallback.removeObject(forKey: defaultName)
            return
        }
        let status = SecItemDelete(baseQuery(defaultName) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            cache[defaultName] = .some(nil)
        } else if switchToFallbackIfUnavailable(status) {
            fallback.removeObject(forKey: defaultName)
        }
    }

    /// Moves each key once from an old plist location into the ledger, then
    /// removes the plist copy so a later hand edit there has no effect. Values
    /// already in the ledger win.
    func migrate(keys: [String], from source: UserDefaults) {
        for key in keys {
            guard let legacy = source.data(forKey: key) else { continue }
            if data(forKey: key) == nil {
                set(legacy, forKey: key)
            }
            if !isUsingFallback || source !== fallback {
                source.removeObject(forKey: key)
            }
        }
    }

    var isUsingFallback: Bool {
        lock.lock()
        defer { lock.unlock() }
        return usesFallback
    }

    private func switchToFallbackIfUnavailable(_ status: OSStatus) -> Bool {
        // -34018: errSecMissingEntitlement. Also treat "not available" and
        // "interaction not allowed" as a missing data-protection Keychain.
        guard status == errSecMissingEntitlement
                || status == errSecNotAvailable
                || status == errSecInteractionNotAllowed else { return false }
        usesFallback = true
        cache.removeAll()
        logger.fault("ledger_fallback_to_defaults status=\(status, privacy: .public) reason=data-protection-keychain-unavailable")
        return true
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}

/// The ledger the Mac app uses for every piece of lock and pause state.
enum MacLockLedger {
    static let pausesKey = "desktop-enforcement.temporary-pauses.v1"
    static let backoffKey = "temporary-allowance.backoff.v1"
    static let sessionExitsKey = "lockdown.mac-session-exits.v1"
    static let retreatUnlocksKey = "lockdown.retreat-unlocks.v1"
    static let ruleEditUnlocksKey = "lockdown.mac-rule-edits.v1"
    static let emergencyDisablesKey = "desktop-enforcement.emergency-disables.v1"

    static let shared = KeychainProtectedLedger()

    /// One-time move of existing state out of the user-editable plists.
    static func migrateLegacyState(
        standard: UserDefaults = .standard,
        appGroup: UserDefaults? = UserDefaults(suiteName: DesktopEnforcementConstants.appGroupIdentifier)
    ) {
        shared.migrate(keys: [pausesKey, backoffKey, sessionExitsKey], from: standard)
        if let appGroup {
            shared.migrate(keys: [retreatUnlocksKey, ruleEditUnlocksKey], from: appGroup)
        }
    }
}
