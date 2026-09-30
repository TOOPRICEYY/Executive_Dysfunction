import Foundation
import os

/// A persisted reference point for deciding what time it really is.
///
/// Rule windows and timed lockdowns are judged against the wall clock, which
/// the device owner can set. Within one boot `mach_continuous_time` cannot be
/// set and keeps counting through sleep, so wall time can be checked against
/// it. Across a reboot the continuous clock restarts; only a high-water mark
/// of time already seen survives, which catches a clock moved backwards but
/// not one moved forwards while powered off.
struct TrustedTimeAnchor: Codable, Equatable, Sendable {
    var clock: SystemClockReading
    var wall: Date
    var highWaterMark: Date
}

enum TrustedClock {
    /// NTP corrections are normally sub-second; two minutes absorbs a slow
    /// sync after wake without letting a deliberate change through.
    static let tolerance: TimeInterval = 120

    struct Evaluation: Equatable, Sendable {
        var trustedNow: Date
        var tampered: Bool
        var anchor: TrustedTimeAnchor
    }

    static func evaluate(
        wall: Date,
        clock: SystemClockReading,
        anchor: TrustedTimeAnchor?
    ) -> Evaluation {
        guard let anchor else {
            return Evaluation(
                trustedNow: wall,
                tampered: false,
                anchor: TrustedTimeAnchor(clock: clock, wall: wall, highWaterMark: wall)
            )
        }

        if !clock.bootIdentifier.isEmpty, clock.bootIdentifier == anchor.clock.bootIdentifier {
            // Same boot: the anchor is never moved within a boot, so a series
            // of small steps cannot walk the clock away one tolerance at a time.
            let elapsed = clock.continuousUptime - anchor.clock.continuousUptime
            let expected = anchor.wall.addingTimeInterval(elapsed)
            let tampered = abs(wall.timeIntervalSince(expected)) > tolerance
            let trusted = tampered ? expected : wall
            var next = anchor
            next.highWaterMark = max(anchor.highWaterMark, trusted)
            return Evaluation(trustedNow: trusted, tampered: tampered, anchor: next)
        }

        // New boot: only a backwards move is detectable.
        let tampered = wall < anchor.highWaterMark.addingTimeInterval(-tolerance)
        let trusted = max(wall, anchor.highWaterMark)
        return Evaluation(
            trustedNow: trusted,
            tampered: tampered,
            anchor: TrustedTimeAnchor(clock: clock, wall: trusted, highWaterMark: trusted)
        )
    }
}

/// Process-wide guard installed only by the web filter.
///
/// When the wall clock disagrees with trusted time, policy evaluation checks
/// both instants and enforces the union: a rule or lockdown active at either
/// time is active. Tampering therefore makes enforcement stricter, never
/// looser, and a legitimate correction the guard mistakes for tampering can
/// only over-block until the next reboot. Outside the filter nothing is
/// installed and evaluation is unchanged.
final class ClockTamperGuard: @unchecked Sendable {
    static let shared = ClockTamperGuard()

    private let lock = NSLock()
    private var defaults: (any KeyValueLedger)?
    private var anchor: TrustedTimeAnchor?
    private var offset: TimeInterval = 0
    private var lastEvaluation = Date.distantPast
    private var lastPersist = Date.distantPast
    private var wasTampered = false
    private let logger = Logger(
        subsystem: "com.GabrielPrice.ExecutiveDysfunction.WebFilter",
        category: "clock-guard"
    )

    static let anchorKey = "clock-guard.anchor.v1"

    /// The filter runs as root, so its defaults domain is not writable by the
    /// signed-in user. The app installs it over the protected ledger so that
    /// unlock waits use the same notion of time.
    func install(defaults: any KeyValueLedger = UserDefaults.standard) {
        lock.lock()
        self.defaults = defaults
        anchor = defaults.data(forKey: Self.anchorKey).flatMap {
            try? JSONDecoder().decode(TrustedTimeAnchor.self, from: $0)
        }
        lastEvaluation = .distantPast
        lock.unlock()
        refresh(wall: Date(), clock: .current(), force: true)
    }

    /// The earlier of wall time and trusted time: the right clock for timing a
    /// wait, since neither direction of clock change can shorten it.
    func conservativeNow(wall: Date = Date()) -> Date {
        guard let trusted = alternateDate(for: wall) else { return wall }
        return min(wall, trusted)
    }

    var isTampered: Bool {
        lock.lock(); defer { lock.unlock() }
        return offset != 0
    }

    /// The instant, in trusted time, that corresponds to `date` on the wall
    /// clock, or nil when the two agree or the guard is not installed.
    func alternateDate(for date: Date) -> Date? {
        lock.lock()
        let installed = defaults != nil
        let stale = Date().timeIntervalSince(lastEvaluation) >= 1
        lock.unlock()
        guard installed else {
            lock.lock(); defer { lock.unlock() }
            return offset == 0 ? nil : date.addingTimeInterval(offset)
        }
        if stale { refresh(wall: Date(), clock: .current(), force: false) }
        lock.lock(); defer { lock.unlock() }
        return offset == 0 ? nil : date.addingTimeInterval(offset)
    }

    func refresh(wall: Date, clock: SystemClockReading, force: Bool) {
        lock.lock()
        let evaluation = TrustedClock.evaluate(wall: wall, clock: clock, anchor: anchor)
        anchor = evaluation.anchor
        offset = evaluation.tampered ? evaluation.trustedNow.timeIntervalSince(wall) : 0
        lastEvaluation = wall
        let transition = evaluation.tampered != wasTampered
        wasTampered = evaluation.tampered
        let shouldPersist = force || transition || wall.timeIntervalSince(lastPersist) >= 60
            || wall < lastPersist
        if shouldPersist { lastPersist = wall }
        let defaults = defaults
        let offset = offset
        lock.unlock()

        if shouldPersist, let defaults, let data = try? JSONEncoder().encode(evaluation.anchor) {
            defaults.set(data, forKey: Self.anchorKey)
        }
        if transition {
            if evaluation.tampered {
                logger.fault("clock_tamper_detected offset_seconds=\(Int(offset), privacy: .public) action=enforce-union")
            } else {
                logger.notice("clock_tamper_cleared")
            }
            TamperJournal.shared.record(
                evaluation.tampered ? .clockTamperDetected : .clockTamperCleared,
                detail: "offset_seconds=\(Int(offset))",
                at: evaluation.trustedNow
            )
        }
    }

    /// Tests only: pretend trusted time is `offset` seconds from the wall.
    func setOffsetForTesting(_ offset: TimeInterval) {
        lock.lock()
        self.offset = offset
        defaults = nil
        lock.unlock()
    }
}
