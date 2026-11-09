import Foundation

/// Durable evidence that enabling the Network Extension was unsafe during one
/// macOS boot session. The containing app keeps blocking disabled until it can
/// prove the Mac has restarted; a relaunch alone must not clear the interlock.
struct MacFilterActivationSafetyRecord: Equatable, Sendable {
    var bootSessionIdentifier: String?
    var estimatedBootTime: Date
    var triggeredAt: Date
    var reason: String
}

enum MacFilterActivationSafetyState: Equatable, Sendable {
    case clear
    case lockedUntilRestart
    case restartObserved
}

enum MacFilterActivationSafetyGate {
    /// Boot-session UUIDs are authoritative when available. The estimated boot
    /// time and trigger time also persist the system uptime at the moment the
    /// record was written (`triggeredAt - estimatedBootTime`). Unlike either
    /// date by itself, that interval is unaffected by later wall-clock or NTP
    /// corrections. A small tolerance absorbs the separate reads used to
    /// construct the record and the current observation.
    static let estimatedBootTimeTolerance: TimeInterval = 5
    static let systemUptimeTolerance: TimeInterval = 5

    static func state(
        record: MacFilterActivationSafetyRecord?,
        currentBootSessionIdentifier: String?,
        currentEstimatedBootTime: Date,
        currentSystemUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> MacFilterActivationSafetyState {
        guard let record else { return .clear }

        if let recordedIdentifier = normalized(record.bootSessionIdentifier),
           let currentIdentifier = normalized(currentBootSessionIdentifier) {
            return recordedIdentifier == currentIdentifier
                ? .lockedUntilRestart
                : .restartObserved
        }

        let recordedSystemUptimeAtTrigger = record.triggeredAt.timeIntervalSince(
            record.estimatedBootTime
        )
        if recordedSystemUptimeAtTrigger.isFinite,
           recordedSystemUptimeAtTrigger >= 0,
           currentSystemUptime.isFinite,
           currentSystemUptime >= 0,
           currentSystemUptime + systemUptimeTolerance < recordedSystemUptimeAtTrigger {
            // Monotonic system uptime cannot move backwards during one boot.
            // This is therefore safe evidence of a restart even if the wall
            // clock moved substantially in either direction.
            return .restartObserved
        }

        let bootTimeDelta = abs(
            record.estimatedBootTime.timeIntervalSince(currentEstimatedBootTime)
        )
        if bootTimeDelta <= estimatedBootTimeTolerance {
            return .lockedUntilRestart
        }

        // A changed wall-clock-derived boot time is not proof of a restart.
        // If current uptime has already reached the recorded uptime, this may
        // be either the same boot after a clock correction or a later launch
        // following a genuine reboot. Keep the safety latch in that rare,
        // UUID-unavailable ambiguous state rather than accidentally enabling.
        return .lockedUntilRestart
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
