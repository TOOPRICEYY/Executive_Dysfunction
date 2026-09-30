import Foundation

/// Why an outbound callback could not be incorporated into the contiguous
/// stream prefix. Raw values are suitable for privacy-safe diagnostics: they
/// describe framework sequencing only, never the bytes or destination.
enum WebFilterStreamingSequenceError: String, Error, Equatable {
    case emptyCallback = "empty_callback"
    case negativeOffset = "negative_offset"
    case offsetGap = "offset_gap"
    case conflictingOverlap = "conflicting_overlap"
    case replayOnly = "replay_only"
    case byteLimitExceeded = "byte_limit_exceeded"
    case staleState = "stale_state"
    case invalidRequirement = "invalid_requirement"
}

struct WebFilterStreamingAppend: Equatable {
    /// Bytes currently awaiting this callback's verdict. This excludes any
    /// overlapping prefix that an unusual callback re-presented after it had
    /// already been passed.
    var pendingBytes: Int
    var overlapBytes: Int
}

struct WebFilterStreamingContinuation: Equatable {
    var passBytes: Int
    var peekBytes: Int
    var passedThroughOffset: Int
}

/// Pure, deterministic bookkeeping for Network Extension's streaming verdicts.
///
/// `peekBytes` in `NEFilterDataVerdict` is relative to the end of `passBytes`,
/// while parser requirements are absolute offsets in the accumulated prefix.
/// Keeping both offsets here prevents an overlap or replay from passing bytes
/// twice. Every successful continuation passes at least one byte, so the byte
/// ceiling also bounds callback count without rejecting a valid 64 KiB hello.
struct WebFilterStreamingInspection: Equatable {
    /// A large initial request wedged every inspected web flow on the live Mac:
    /// the framework waited for the requested count while the client waited for
    /// the server. One byte guarantees the first payload callback can run.
    static let initialPeekBytes = 1

    /// Once TLS has declared an exact record length, release its prefix in small
    /// bounded pieces. The piece completing a blocked ClientHello is withheld.
    static let maximumPeekBytes = 512

    /// Shared with the parser so neither callback count nor retained memory can
    /// grow without bound. HTTP has a smaller limit of its own.
    static let maximumRetainedBytes = NetworkHostnameInspector.maximumClientHelloBytes

    private(set) var prefix = Data()
    private(set) var passedThroughOffset = 0
    private(set) var callbacks = 0

    var pendingBytes: Int {
        max(0, prefix.count - passedThroughOffset)
    }

    /// Adds a callback at its absolute stream offset. Once bytes have been
    /// passed, Network Extension's `passBytes` count starts at the callback's
    /// first byte; it cannot skip a re-presented overlap. We therefore require
    /// the callback to begin exactly at the first byte not yet passed. Empty,
    /// overlapping, gapped, or replayed callbacks are ambiguous and release the
    /// flow safely instead of risking duplicated or mis-accounted bytes.
    mutating func append(_ readBytes: Data, at offset: Int) -> Result<WebFilterStreamingAppend, WebFilterStreamingSequenceError> {
        guard !readBytes.isEmpty else { return .failure(.emptyCallback) }
        guard offset >= 0 else { return .failure(.negativeOffset) }
        if offset < passedThroughOffset { return .failure(.replayOnly) }
        if offset > passedThroughOffset { return .failure(.offsetGap) }
        let (endOffset, overflow) = offset.addingReportingOverflow(readBytes.count)
        guard !overflow else { return .failure(.byteLimitExceeded) }
        guard offset == prefix.count else { return .failure(.conflictingOverlap) }
        guard endOffset <= Self.maximumRetainedBytes else {
            return .failure(.byteLimitExceeded)
        }
        prefix.append(readBytes)
        callbacks += 1

        let pending = pendingBytes
        guard pending > 0 else { return .failure(.replayOnly) }
        return .success(
            WebFilterStreamingAppend(
                pendingBytes: pending,
                overlapBytes: 0
            )
        )
    }

    /// Converts an absolute parser requirement into the relative verdict that
    /// Network Extension expects. All currently pending bytes are released;
    /// the next request is exact when fewer than 512 bytes remain.
    mutating func continueInspection(
        requiredPrefixBytes: Int
    ) -> Result<WebFilterStreamingContinuation, WebFilterStreamingSequenceError> {
        let passBytes = pendingBytes
        guard passBytes > 0,
              requiredPrefixBytes > prefix.count,
              requiredPrefixBytes <= Self.maximumRetainedBytes else {
            return .failure(.invalidRequirement)
        }

        let remaining = requiredPrefixBytes - prefix.count
        let peekBytes = min(Self.maximumPeekBytes, remaining)
        guard peekBytes > 0 else { return .failure(.invalidRequirement) }

        passedThroughOffset = prefix.count
        return .success(
            WebFilterStreamingContinuation(
                passBytes: passBytes,
                peekBytes: peekBytes,
                passedThroughOffset: passedThroughOffset
            )
        )
    }
}
