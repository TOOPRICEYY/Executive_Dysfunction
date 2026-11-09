import Foundation

/// A narrowly bounded request used by the external macOS connectivity harness.
/// The app refuses an unbounded or stale request before changing Network
/// Extension preferences.
struct MacFilterSmokeTestRequest: Equatable {
    static let enableFlag = "--enable-web-filter-smoke-test"
    static let identifierPrefix = "--smoke-test-id="
    static let deadlinePrefix = "--smoke-test-deadline-ms="
    static let maximumDuration: TimeInterval = 30
    static let minimumDuration: TimeInterval = 3

    var identifier: UUID
    var deadline: Date

    enum ParseError: Error, Equatable, LocalizedError {
        case missingIdentifier
        case invalidIdentifier
        case missingDeadline
        case invalidDeadline
        case deadlineNotInFuture
        case durationTooLong

        var errorDescription: String? {
            switch self {
            case .missingIdentifier: "The smoke-test identifier is missing."
            case .invalidIdentifier: "The smoke-test identifier is invalid."
            case .missingDeadline: "The smoke-test deadline is missing."
            case .invalidDeadline: "The smoke-test deadline is invalid."
            case .deadlineNotInFuture: "The smoke-test deadline is not safely in the future."
            case .durationTooLong: "The smoke-test deadline exceeds the 30-second safety limit."
            }
        }
    }

    static func parse(
        arguments: [String] = CommandLine.arguments,
        now: Date = Date()
    ) throws -> MacFilterSmokeTestRequest? {
        guard arguments.contains(enableFlag) else { return nil }

        guard let identifierValue = value(withPrefix: identifierPrefix, in: arguments) else {
            throw ParseError.missingIdentifier
        }
        guard let identifier = UUID(uuidString: identifierValue) else {
            throw ParseError.invalidIdentifier
        }
        guard let deadlineValue = value(withPrefix: deadlinePrefix, in: arguments) else {
            throw ParseError.missingDeadline
        }
        guard let milliseconds = Double(deadlineValue), milliseconds.isFinite else {
            throw ParseError.invalidDeadline
        }

        let deadline = Date(timeIntervalSince1970: milliseconds / 1_000)
        let duration = deadline.timeIntervalSince(now)
        guard duration >= minimumDuration else { throw ParseError.deadlineNotInFuture }
        guard duration <= maximumDuration else { throw ParseError.durationTooLong }
        return MacFilterSmokeTestRequest(identifier: identifier, deadline: deadline)
    }

    private static func value(withPrefix prefix: String, in arguments: [String]) -> String? {
        arguments.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
    }
}

enum MacFilterSmokeTestRecoveryDisposition: Equatable {
    case none
    case forcedHealthyDisable
    case forcedUnsafeDisable
    case abandonedRun

    static func resolve(arguments: [String], hasActiveMarker: Bool) -> Self {
        guard hasActiveMarker else { return .none }
        guard arguments.contains("--disable-web-filter-now") else { return .abandonedRun }
        return arguments.contains("--mark-filter-startup-unsafe")
            ? .forcedUnsafeDisable
            : .forcedHealthyDisable
    }
}
