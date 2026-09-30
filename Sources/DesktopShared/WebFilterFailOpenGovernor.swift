import Foundation

/// Why a flow was dropped, for the purposes of the drop-pressure monitor.
///
/// The distinction is the whole point of the valve. A user hammering reload on
/// a site they asked to be blocked must be able to generate an unlimited number
/// of drops without switching enforcement off — otherwise the valve is itself a
/// trivial bypass. Only drops the filter made *without* identifying the
/// destination can be collateral, so only those are counted.
enum WebFilterDropKind: Equatable {
    /// The destination was identified and a rule named it. Intentional.
    case named
    /// Nothing about the destination was identified; the drop was a guess made
    /// by a fail-closed rule. This is the shape every outage has taken.
    case unidentified
}

/// A point-in-time, privacy-safe view with legacy circuit-breaker fields.
struct WebFilterFailOpenState: Equatable {
    var isOpen: Bool
    var openUntil: Date?
    var trips: Int
    var unidentifiedDropsInWindow: Int
    var warningActive: Bool = false
}

/// Reports unusual drop pressure without changing enforcement. A burst can be
/// caused by retries or intentional Fortress restrictions, so it is not proof
/// of an outage and must not grant a five-minute global bypass. The containing
/// app offers the ordinary offline confirmation passage for recovery instead.
/// The type name and legacy fields remain for diagnostic compatibility.
///
/// Counting uses two fixed-width buckets rather than a list of timestamps, so
/// `record` stays allocation-free on the flow path.
final class WebFilterFailOpenGovernor: @unchecked Sendable {
    /// Unidentified drops within `window` that raise a warning.
    ///
    /// Sized well above ordinary enforcement. A page load opens tens of flows,
    /// and a blocked page the user retries produces *named* drops, which are
    /// not counted at all. Sustained unidentified drops may indicate collateral
    /// blocking, but do not prove a fault or authorize changing enforcement.
    static let defaultThreshold = 200
    static let defaultWindow: TimeInterval = 60
    /// Deduplicate warnings for this long; enforcement continues throughout.
    static let defaultCooldown: TimeInterval = 300

    private let threshold: Int
    private let window: TimeInterval
    private let cooldown: TimeInterval
    private let lock = NSLock()

    private var bucketStart: Date
    private var currentBucket = 0
    private var previousBucket = 0
    private var openedAt: Date?
    private var tripCount = 0

    init(
        threshold: Int = defaultThreshold,
        window: TimeInterval = defaultWindow,
        cooldown: TimeInterval = defaultCooldown,
        now: Date = Date()
    ) {
        self.threshold = threshold
        self.window = window
        self.cooldown = cooldown
        bucketStart = now
    }

    /// Drop pressure alone never authorizes bypassing the policy.
    func isFailedOpen(at now: Date = Date()) -> Bool {
        state(at: now).isOpen
    }

    /// Exposes warning state for the heartbeat without flow or destination data.
    func state(at now: Date = Date()) -> WebFilterFailOpenState {
        lock.lock(); defer { lock.unlock() }
        let warningActive = isOpenLocked(at: now)
        if !warningActive { advanceBucketsLocked(to: now) }
        return WebFilterFailOpenState(
            isOpen: false,
            openUntil: nil,
            trips: 0,
            unidentifiedDropsInWindow: warningActive ? 0 : rateLocked(),
            warningActive: warningActive
        )
    }

    /// Records one drop and returns true if this call raised a warning, so the
    /// caller can log the transition exactly once.
    @discardableResult
    func record(_ kind: WebFilterDropKind, at now: Date = Date()) -> Bool {
        guard kind == .unidentified else { return false }
        lock.lock(); defer { lock.unlock() }
        guard !isOpenLocked(at: now) else { return false }

        advanceBucketsLocked(to: now)
        currentBucket += 1
        guard rateLocked() >= threshold else { return false }
        openedAt = now
        tripCount += 1
        currentBucket = 0
        previousBucket = 0
        return true
    }

    /// How many drop-pressure warnings have been raised since startup.
    var trips: Int {
        lock.lock(); defer { lock.unlock() }
        return tripCount
    }

    private func isOpenLocked(at now: Date) -> Bool {
        guard let openedAt else { return false }
        if now.timeIntervalSince(openedAt) < cooldown { return true }
        // Re-arm warning detection; enforcement never stopped.
        self.openedAt = nil
        bucketStart = now
        currentBucket = 0
        previousBucket = 0
        return false
    }

    /// Two half-windows give a rolling count without retaining timestamps. The
    /// estimate is between one and two half-windows wide, which is precise
    /// enough for a threshold two orders of magnitude above normal traffic.
    private func advanceBucketsLocked(to now: Date) {
        let half = window / 2
        let elapsed = now.timeIntervalSince(bucketStart)
        guard elapsed >= half else { return }
        if elapsed >= window {
            previousBucket = 0
            currentBucket = 0
        } else {
            previousBucket = currentBucket
            currentBucket = 0
        }
        bucketStart = now
    }

    private func rateLocked() -> Int { currentBucket + previousBucket }
}
