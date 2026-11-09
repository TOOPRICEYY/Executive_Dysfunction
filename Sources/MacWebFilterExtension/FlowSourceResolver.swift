import Foundation
import Security

/// Resolves the code-signing identity behind a flow.
///
/// macOS gives a content filter an audit token rather than the bundle
/// identifier iOS provides. Translating it costs a Security round trip, which
/// is far too expensive to repeat per flow, so the provider calls this only
/// while an application rule is active or an otherwise-denied authentication
/// flow needs the captive-login exception. Results are memoised per process
/// instance. The pid *version* is part of the key so a recycled pid can never
/// inherit a previous process's identity.
final class FlowSourceResolver: @unchecked Sendable {
    struct Identity: Equatable {
        var signingIdentifier: String?
        var executablePath: String
        var isVerifiedCaptivePortalComponent = false
    }

    private struct Key: Hashable {
        var pid: UInt32
        var pidVersion: UInt32
    }

    private let lock = NSLock()
    private var cache: [Key: Identity] = [:]
    private let cacheLimit = 512

    func identity(forAuditToken tokenData: Data?) -> Identity? {
        guard let tokenData, tokenData.count == MemoryLayout<audit_token_t>.size else { return nil }
        let words = tokenData.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: UInt32.self))
        }
        guard words.count == 8 else { return nil }
        let key = Key(pid: words[5], pidVersion: words[7])

        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = resolve(tokenData: tokenData)
        lock.lock()
        // A plain reset keeps the cache bounded without a full LRU. Filters see
        // a small working set of processes, so this rarely triggers.
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = resolved
        lock.unlock()
        return resolved
    }

    private func resolve(tokenData: Data) -> Identity {
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else {
            return Identity(signingIdentifier: nil, executablePath: "")
        }

        var staticCode: SecStaticCode?
        var path = ""
        if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode {
            var url: CFURL?
            if SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let url {
                path = (url as URL).path
            }
        }

        // A crash or long synchronous stall here withholds Network Extension
        // verdicts. Nothing in this path may force-unwrap or reinterpret a type
        // it has not been handed.
        guard let staticCode else { return Identity(signingIdentifier: nil, executablePath: path) }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let dictionary = information as? [String: Any] else {
            return Identity(signingIdentifier: nil, executablePath: path)
        }

        let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String
        var isVerifiedCaptivePortalComponent = false
        if MacCaptivePortalPolicy.isSystemComponent(signingIdentifier: identifier, executablePath: path) {
            // Validate the live audit-token owner, not a self-asserted signing
            // identifier. Only the two exact protected OS executables qualify.
            var requirement: SecRequirement?
            if SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
               let requirement {
                isVerifiedCaptivePortalComponent = SecCodeCheckValidity(code, [], requirement) == errSecSuccess
            }
        }
        return Identity(
            signingIdentifier: identifier,
            executablePath: path,
            isVerifiedCaptivePortalComponent: isVerifiedCaptivePortalComponent
        )
    }
}
