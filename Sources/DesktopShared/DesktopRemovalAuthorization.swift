import Foundation
import Security

/// Uninstalling the filter is the strongest possible weakening of the policy,
/// and until now it was the only weakening that skipped the passage/delay gate
/// entirely. A rule the user cannot loosen without waiting days is worth
/// nothing behind a Remove button that answers in two seconds.
///
/// This file holds the decision logic only. It performs no I/O and takes its
/// clock readings as parameters so the whole gate is testable.

/// A monotonic clock reading that survives sleep but not reboot.
///
/// The wall clock belongs to the administrator: moving it forward would
/// otherwise mature a pending removal instantly. `mach_continuous_time` cannot
/// be set, and `kern.bootsessionuuid` tells us whether it is comparable with
/// the reading taken when the removal was requested.
struct SystemClockReading: Codable, Equatable, Sendable {
    var bootIdentifier: String
    var continuousUptime: TimeInterval

    static func current() -> SystemClockReading {
        SystemClockReading(
            bootIdentifier: Self.bootSessionIdentifier(),
            continuousUptime: Self.continuousUptime()
        )
    }

    /// Stable for the life of a boot, and unaffected by clock changes. A
    /// `kern.boottime` reading would not do: it is expressed in wall time and
    /// moves whenever the clock is set.
    private static func bootSessionIdentifier() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else {
            return ""
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else {
            return ""
        }
        return String(cString: buffer)
    }

    /// `ProcessInfo.systemUptime` stops while the machine is asleep, which on a
    /// laptop would stall a multi-day wait indefinitely. The continuous clock
    /// keeps counting through sleep.
    private static func continuousUptime() -> TimeInterval {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return 0 }
        let nanoseconds = Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom)
        return nanoseconds / 1_000_000_000
    }
}

/// A pending uninstall. Recorded before anything is torn down, so a removal
/// that is merely *requested* leaves enforcement fully intact.
struct DesktopRemovalRequest: Codable, Equatable, Sendable {
    var id: UUID
    var requestedAt: Date
    var delaySeconds: TimeInterval
    var confirmationWindowSeconds: TimeInterval
    var requiredPassage: String
    var clockAtRequest: SystemClockReading
}

enum DesktopRemovalGate {
    /// What the current policy demands before it can be uninstalled, derived
    /// from the strictest locked rule in force.
    struct Terms: Equatable, Sendable {
        var delaySeconds: TimeInterval
        var confirmationWindowSeconds: TimeInterval
        var passageWordCount: Int

        static let unlocked = Terms(
            delaySeconds: 0,
            confirmationWindowSeconds: 3_600,
            passageWordCount: 0
        )
    }

    enum State: Equatable, Sendable {
        case notRequested
        /// The delay is still running. Enforcement continues throughout.
        case waiting(remaining: TimeInterval)
        /// Inside the confirmation window; the passage will now be accepted.
        case ready(remaining: TimeInterval, passage: String)
        /// The window closed unused. The wait starts again from zero.
        case expired
    }

    /// Only rules that are enabled *and* locked contribute. An unlocked rule
    /// carries no promise the user asked to be held to.
    static func terms(for policy: DesktopEnforcementPolicy) -> Terms {
        let locked = policy.rules.filter { $0.isEnabled && $0.lockdown.severity != "none" }
        guard !locked.isEmpty else { return .unlocked }

        let delayDays = locked.map(\.lockdown.unlockDelayDays).max() ?? 0
        let passageWords = locked.map(\.lockdown.passageWordCount).max() ?? 0
        // A shorter edit window is the stricter setting, so the strictest rule
        // sets the deadline for everyone.
        let windowHours = locked.map(\.lockdown.editWindowHours).min() ?? 1

        return Terms(
            // Any locked rule earns at least a day. A rule locked with a
            // zero-day delay still should not be removable on impulse.
            delaySeconds: TimeInterval(max(1, delayDays)) * 86_400,
            confirmationWindowSeconds: TimeInterval(max(1, windowHours)) * 3_600,
            passageWordCount: max(0, passageWords)
        )
    }

    static func makeRequest(
        for policy: DesktopEnforcementPolicy,
        at now: Date = Date(),
        clock: SystemClockReading = .current(),
        id: UUID = UUID()
    ) -> DesktopRemovalRequest {
        let terms = terms(for: policy)
        return DesktopRemovalRequest(
            id: id,
            requestedAt: now,
            delaySeconds: terms.delaySeconds,
            confirmationWindowSeconds: terms.confirmationWindowSeconds,
            requiredPassage: passage(wordCount: terms.passageWordCount, seed: id),
            clockAtRequest: clock
        )
    }

    static func state(
        for request: DesktopRemovalRequest?,
        at now: Date = Date(),
        clock: SystemClockReading = .current()
    ) -> State {
        guard let request else { return .notRequested }
        let elapsed = elapsedSeconds(since: request, at: now, clock: clock)

        if elapsed < request.delaySeconds {
            return .waiting(remaining: request.delaySeconds - elapsed)
        }
        let closesAt = request.delaySeconds + request.confirmationWindowSeconds
        if elapsed >= closesAt { return .expired }
        return .ready(remaining: closesAt - elapsed, passage: request.requiredPassage)
    }

    /// Takes the *lesser* of wall-clock and monotonic elapsed time, so neither
    /// direction of clock tampering shortens the wait. Moving the clock forward
    /// is capped by the continuous clock; moving it back is capped by itself.
    ///
    /// Across a reboot the monotonic anchor is meaningless and only wall time
    /// remains. That residual gap is narrower than the alternative of stalling
    /// every pending removal at every restart.
    static func elapsedSeconds(
        since request: DesktopRemovalRequest,
        at now: Date,
        clock: SystemClockReading
    ) -> TimeInterval {
        let wallClock = max(0, now.timeIntervalSince(request.requestedAt))
        guard !clock.bootIdentifier.isEmpty,
              clock.bootIdentifier == request.clockAtRequest.bootIdentifier else {
            return wallClock
        }
        let monotonic = max(0, clock.continuousUptime - request.clockAtRequest.continuousUptime)
        return min(wallClock, monotonic)
    }

    /// Compared on words rather than characters so that stray whitespace, case,
    /// and line breaks do not turn a deliberate act into a frustrating one.
    static func passageMatches(_ typed: String, request: DesktopRemovalRequest) -> Bool {
        func words(_ value: String) -> [String] {
            value.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        }
        let required = words(request.requiredPassage)
        guard !required.isEmpty else { return true }
        return words(typed) == required
    }

    /// Deterministic in the request's identifier, so the phrase survives a
    /// relaunch and cannot be re-rolled for a shorter one by reopening the sheet.
    static func passage(wordCount: Int, seed: UUID) -> String {
        guard wordCount > 0 else { return "" }
        let bytes = withUnsafeBytes(of: seed.uuid) { Array($0) }
        var result: [String] = []
        for index in 0..<wordCount {
            // Widen past the 16 UUID bytes without repeating the cycle exactly.
            let a = Int(bytes[index % bytes.count])
            let b = Int(bytes[(index * 7 + 3) % bytes.count])
            result.append(passageVocabulary[(a &* 31 &+ b &+ index) % passageVocabulary.count])
        }
        return result.joined(separator: " ")
    }

    /// Ordinary, unambiguous words: the passage is meant to cost attention, not
    /// to be hard to transcribe.
    private static let passageVocabulary = [
        "anchor", "beacon", "candle", "harbor", "lantern", "meadow", "orchard", "pebble",
        "quarry", "ribbon", "saddle", "timber", "velvet", "willow", "yonder", "amber",
        "bridge", "cavern", "domain", "ember", "forest", "gravel", "hollow", "island",
        "kettle", "ladder", "marble", "needle", "onward", "prairie", "quiver", "rafter",
        "silver", "thicket", "upward", "vessel", "wander", "yellow", "acorn", "basalt",
        "cinder", "driftwood", "eastern", "fathom", "granite", "hearth", "inland", "juniper",
        "kindle", "lumber", "mantle", "northern", "obsidian", "plateau", "quartz", "reason",
        "summit", "tundra", "upland", "valley", "western", "yardarm", "zenith", "alcove"
    ]
}

// MARK: - Persistence

protocol DesktopRemovalRequestPersisting: AnyObject {
    func load() -> DesktopRemovalRequest?
    func save(_ request: DesktopRemovalRequest) throws
    func clear()
}

final class InMemoryRemovalRequestStore: DesktopRemovalRequestPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DesktopRemovalRequest?

    init(_ initial: DesktopRemovalRequest? = nil) { stored = initial }

    func load() -> DesktopRemovalRequest? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func save(_ request: DesktopRemovalRequest) throws {
        lock.lock(); defer { lock.unlock() }
        stored = request
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        stored = nil
    }
}

/// Keychain rather than `UserDefaults`: a pending removal recorded in defaults
/// could be matured with a single `defaults write` of an earlier `requestedAt`.
final class KeychainRemovalRequestStore: DesktopRemovalRequestPersisting {
    private let service = "com.GabrielPrice.ExecutiveDysfunction.pending-removal.v1"
    private let account = "pending-removal-request"

    func load() -> DesktopRemovalRequest? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(DesktopRemovalRequest.self, from: data)
    }

    func save(_ request: DesktopRemovalRequest) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(request)
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw DesktopPolicyError.keychain(updateStatus) }
        } else if status != errSecSuccess {
            throw DesktopPolicyError.keychain(status)
        }
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
