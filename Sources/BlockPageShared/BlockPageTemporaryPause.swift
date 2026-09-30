import Darwin
import Foundation

struct BlockPageRuleDescriptor: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var enforcementMode: String
    var domains: [String]
    var allowsTimeExtensions: Bool
    var passageWordCount: Int
    var policyFingerprint: String
    var requiresAppForTemporaryAccess: Bool? = nil
}

enum BlockPageRuleMatcher {
    static func rulesBlocking(
        host rawHost: String,
        among rules: [BlockPageRuleDescriptor]
    ) -> [BlockPageRuleDescriptor] {
        guard let host = BlockPageHostPolicy.normalizedDomain(rawHost) else { return [] }
        return rules.filter { rule in
            switch rule.enforcementMode {
            case "blockList":
                return rule.domains.contains { domainMatches(host, ruleDomain: $0) }
            case "fortressAllowList":
                return !rule.domains.contains { domainMatches(host, ruleDomain: $0) }
            default:
                return false
            }
        }
    }

    static func eligibleRules(
        host: String,
        among rules: [BlockPageRuleDescriptor]
    ) -> [BlockPageRuleDescriptor] {
        rulesBlocking(host: host, among: rules)
            .filter { rule in
                rule.allowsTimeExtensions
                    && rule.requiresAppForTemporaryAccess != true
                    && (20...300).contains(rule.passageWordCount)
                    && isValidFingerprint(rule.policyFingerprint)
            }
            .sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame
                    ? $0.id.uuidString < $1.id.uuidString
                    : order == .orderedAscending
            }
    }

    static func isValidFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
        }
    }

    private static func domainMatches(_ host: String, ruleDomain rawRuleDomain: String) -> Bool {
        guard let ruleDomain = BlockPageHostPolicy.normalizedDomain(rawRuleDomain) else {
            return false
        }
        let canonicalHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let canonicalRule = ruleDomain.hasPrefix("www.")
            ? String(ruleDomain.dropFirst(4))
            : ruleDomain
        return canonicalHost == canonicalRule || canonicalHost.hasSuffix("." + canonicalRule)
    }
}

struct BlockPageTemporaryPause: Codable, Equatable, Sendable {
    var ruleID: UUID
    var policyRevision: UInt64
    var policyFingerprint: String
    var grantedAt: Date
    var expiresAt: Date
    var durationSeconds: Int
    var requestID: UUID

    func isActive(at date: Date) -> Bool {
        grantedAt <= date && date < expiresAt
    }

    func isStructurallyValid(clockSkew: TimeInterval = 5) -> Bool {
        guard BlockPagePauseDuration.allowedSeconds.contains(durationSeconds),
              BlockPageRuleMatcher.isValidFingerprint(policyFingerprint),
              expiresAt > grantedAt else { return false }
        return abs(expiresAt.timeIntervalSince(grantedAt) - Double(durationSeconds)) <= clockSkew
    }
}

enum BlockPagePauseDuration {
    static let allowedSeconds = [600, 1_800, 3_600]

    static func label(for seconds: Int) -> String? {
        switch seconds {
        case 600: "10 minutes"
        case 1_800: "30 minutes"
        case 3_600: "60 minutes"
        default: nil
        }
    }
}

struct BlockPageTemporaryPauseDocument: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var pauses: [BlockPageTemporaryPause] = []
    @BypassEventBuffer var bypassHistory: [BypassEvent]? = nil
}

enum BlockPagePauseStoreError: Error, Equatable {
    case unsafeDirectory
    case unsafeFile
    case corruptDocument
    case invalidPause
    case unsupportedSchema(Int)
    case posix(Int32)
}

/// Root-to-root persistence shared by the loopback block-page daemon and the
/// content-filter provider. The daemon is the sole writer. The provider treats
/// every record as a request and independently validates it against its current
/// authenticated policy before excluding a rule.
final class BlockPageTemporaryPauseStore: @unchecked Sendable {
    static let defaultURL = URL(
        fileURLWithPath: "/Library/Application Support/ExecutiveDysfunction/blockpage/temporary-pauses.json"
    )

    let fileURL: URL
    private let requiresRootOwnership: Bool
    private let lock = NSLock()

    init(fileURL: URL = defaultURL, requiresRootOwnership: Bool = true) {
        self.fileURL = fileURL
        self.requiresRootOwnership = requiresRootOwnership
    }

    func activePauses(at now: Date = Date()) throws -> [BlockPageTemporaryPause] {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked(at: now)
    }

    /// Replaces any existing pause for this rule. Durations never stack, so a
    /// repeated deliberate confirmation starts one new bounded interval.
    func grant(_ pause: BlockPageTemporaryPause, at now: Date = Date(), ruleName: String = "Blocking Group", intent: BypassEvent.Intent? = nil) throws {
        guard pause.isStructurallyValid(),
              pause.grantedAt <= now.addingTimeInterval(5),
              pause.expiresAt > now else {
            throw BlockPagePauseStoreError.invalidPause
        }

        lock.lock()
        defer { lock.unlock() }
        var document = try loadDocumentUnlocked()
        var pauses = document.pauses.filter { $0.isStructurallyValid() && $0.isActive(at: now) }
        pauses.removeAll { $0.ruleID == pause.ruleID }
        pauses.append(pause)
        pauses.sort { $0.ruleID.uuidString < $1.ruleID.uuidString }
        document.pauses = pauses
        var history = document.bypassHistory ?? []
        if !history.contains(where: { $0.id == pause.requestID }) {
            history.append(BypassEvent(id: pause.requestID, groupID: pause.ruleID, groupName: ruleName,
                grantedAt: pause.grantedAt, expiresAt: pause.expiresAt,
                grantedMinutes: pause.durationSeconds / 60, source: .browser, intent: intent))
        }
        document.bypassHistory = Array(history.suffix(1_000))
        try writeUnlocked(document)
    }

    /// Read on the provider's settings queue, never on a flow callback. The app
    /// receives a read-only mirror in status; the root-owned file stays private.
    func bypassEvents(at now: Date = Date()) throws -> [BypassEvent] {
        lock.lock(); defer { lock.unlock() }
        let document = try loadDocumentUnlocked()
        return document.bypassHistory ?? document.pauses.filter { $0.isStructurallyValid() && $0.isActive(at: now) }.map {
            BypassEvent(id: $0.requestID, groupID: $0.ruleID, groupName: "Blocking Group",
                grantedAt: $0.grantedAt, expiresAt: $0.expiresAt, grantedMinutes: $0.durationSeconds / 60, source: .browser)
        }
    }

    func pruneExpired(at now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        var existing = try loadDocumentUnlocked()
        let active = existing.pauses.filter { $0.isStructurallyValid() && $0.isActive(at: now) }
        guard active != existing.pauses else { return }
        existing.pauses = active
        try writeUnlocked(existing)
    }

    private func loadUnlocked(at now: Date) throws -> [BlockPageTemporaryPause] {
        try loadDocumentUnlocked().pauses.filter {
            $0.isStructurallyValid() && $0.isActive(at: now)
        }
    }

    private func loadDocumentUnlocked() throws -> BlockPageTemporaryPauseDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return BlockPageTemporaryPauseDocument()
        }
        try validateExistingFile()
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch let error as POSIXError {
            throw BlockPagePauseStoreError.posix(error.code.rawValue)
        } catch {
            throw BlockPagePauseStoreError.corruptDocument
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let document = try? decoder.decode(BlockPageTemporaryPauseDocument.self, from: data) else {
            throw BlockPagePauseStoreError.corruptDocument
        }
        guard document.schemaVersion == 1 else {
            throw BlockPagePauseStoreError.unsupportedSchema(document.schemaVersion)
        }
        return document
    }

    private func writeUnlocked(_ document: BlockPageTemporaryPauseDocument) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch let error as POSIXError {
            throw BlockPagePauseStoreError.posix(error.code.rawValue)
        } catch {
            throw BlockPagePauseStoreError.unsafeDirectory
        }
        try validateDirectory(directory)

        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(document)
        } catch {
            throw BlockPagePauseStoreError.corruptDocument
        }

        let directoryPath = directory.path
        let temporaryName = ".temporary-pauses.\(UUID().uuidString.lowercased())"
        let temporaryPath = directory.appendingPathComponent(temporaryName).path
        let fileDescriptor = Darwin.open(
            temporaryPath,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard fileDescriptor >= 0 else { throw BlockPagePauseStoreError.posix(errno) }

        var shouldUnlink = true
        defer {
            Darwin.close(fileDescriptor)
            if shouldUnlink { Darwin.unlink(temporaryPath) }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard var cursor = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(fileDescriptor, cursor, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw BlockPagePauseStoreError.posix(errno)
                }
                remaining -= written
                cursor = cursor.advanced(by: written)
            }
        }
        guard fchmod(fileDescriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw BlockPagePauseStoreError.posix(errno)
        }
        if requiresRootOwnership, fchown(fileDescriptor, 0, 0) != 0 {
            throw BlockPagePauseStoreError.posix(errno)
        }
        guard fsync(fileDescriptor) == 0 else { throw BlockPagePauseStoreError.posix(errno) }
        guard rename(temporaryPath, fileURL.path) == 0 else {
            throw BlockPagePauseStoreError.posix(errno)
        }
        shouldUnlink = false

        let directoryDescriptor = Darwin.open(directoryPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if directoryDescriptor >= 0 {
            _ = fsync(directoryDescriptor)
            Darwin.close(directoryDescriptor)
        }
    }

    private func validateDirectory(_ directory: URL) throws {
        var status = stat()
        guard lstat(directory.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              (status.st_mode & mode_t(S_IWGRP | S_IWOTH)) == 0 else {
            throw BlockPagePauseStoreError.unsafeDirectory
        }
        if requiresRootOwnership, status.st_uid != 0 {
            throw BlockPagePauseStoreError.unsafeDirectory
        }
    }

    private func validateExistingFile() throws {
        var status = stat()
        guard lstat(fileURL.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              (status.st_mode & mode_t(S_IRWXG | S_IRWXO)) == 0 else {
            throw BlockPagePauseStoreError.unsafeFile
        }
        if requiresRootOwnership, status.st_uid != 0 {
            throw BlockPagePauseStoreError.unsafeFile
        }
    }
}
