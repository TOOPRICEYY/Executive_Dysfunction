import Foundation

struct BlockPageFilterState: Equatable {
    var hasActiveWebRestrictions: Bool
    var updatedAt: Date
    var blockedDomains: [String]
}

enum BlockPageHostPolicy {
    static let markerBegin = "# BEGIN Holdfast block page"
    static let markerEnd = "# END Holdfast block page"
    static let legacyMarkerBegin = "# BEGIN ExecutiveDysfunction block page"
    static let legacyMarkerEnd = "# END ExecutiveDysfunction block page"
    static let statusFreshness: TimeInterval = 12

    static func mappedDomains(
        state: BlockPageFilterState?,
        configuredDomains: [String],
        now: Date = Date()
    ) -> [String] {
        guard let state,
              state.hasActiveWebRestrictions,
              now.timeIntervalSince(state.updatedAt) >= 0,
              now.timeIntervalSince(state.updatedAt) <= statusFreshness else { return [] }

        let configured = Set(configuredDomains.compactMap(normalizedDomain))
        let active = Set(state.blockedDomains.compactMap(normalizedDomain).flatMap { domain in
            let base = domain.hasPrefix("www.") ? String(domain.dropFirst(4)) : domain
            return [base, "www." + base]
        })
        return configured.intersection(active).sorted()
    }

    /// Replaces only this product's fully marked block. A malformed one-sided
    /// marker returns nil rather than risking removal of unrelated host entries.
    static func replacingManagedBlock(in contents: String, domains: [String]) -> String? {
        var lines = contents.components(separatedBy: .newlines)
        var managedRanges: [ClosedRange<Int>] = []
        for (beginMarker, endMarker) in [
            (markerBegin, markerEnd),
            (legacyMarkerBegin, legacyMarkerEnd)
        ] {
            let beginIndexes = lines.indices.filter { lines[$0] == beginMarker }
            let endIndexes = lines.indices.filter { lines[$0] == endMarker }
            guard beginIndexes.count == endIndexes.count,
                  beginIndexes.count <= 1 else { return nil }
            if let begin = beginIndexes.first, let end = endIndexes.first {
                guard begin < end else { return nil }
                managedRanges.append(begin...end)
            }
        }
        let orderedRanges = managedRanges.sorted(by: { $0.lowerBound < $1.lowerBound })
        // Mixed legacy/current markers can be nested or interleaved after a
        // malformed migration. Removing either range would invalidate the
        // other's indices and could crash the daemon or remove unrelated lines.
        for pair in zip(orderedRanges, orderedRanges.dropFirst()) {
            guard pair.0.upperBound < pair.1.lowerBound else { return nil }
        }
        for range in orderedRanges.reversed() {
            lines.removeSubrange(range)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }

        let normalized = Set(domains.compactMap(normalizedDomain)).sorted()
        if !normalized.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append(markerBegin)
            lines.append(contentsOf: normalized.map { "127.0.0.1 \($0)" })
            lines.append(markerEnd)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func normalizedDomain(_ raw: String) -> String? {
        var domain = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while domain.hasSuffix(".") { domain.removeLast() }
        guard !domain.isEmpty,
              !domain.contains("/"),
              domain.utf8.allSatisfy({ byte in
                  (byte >= 0x61 && byte <= 0x7a)
                      || (byte >= 0x30 && byte <= 0x39)
                      || byte == 0x2d
                      || byte == 0x2e
              }) else { return nil }
        return domain
    }
}
