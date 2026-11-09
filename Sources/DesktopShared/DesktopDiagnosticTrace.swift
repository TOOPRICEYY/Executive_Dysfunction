import Darwin
import Foundation

struct DesktopDiagnosticTraceEvent: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion = Self.schemaVersion
    var timestampMilliseconds: Int64
    var process: String
    var processIdentifier: Int32
    var build: String
    var component: String
    var event: String
    var fields: [String: String]
}

/// A small, structured, privacy-conscious activity trace shared by the app and
/// its provider. It complements Unified Logging with evidence that survives
/// process replacement and can be exported without granting Console access.
///
/// Callers must use counts, state names, operation IDs, and error codes. Do not
/// pass hostnames, URLs, page content, application identities, or payload data.
final class DesktopDiagnosticTraceFileStore: @unchecked Sendable {
    private static let processLock = NSLock()

    let fileURL: URL
    let maximumBytes: Int

    init(fileURL: URL, maximumBytes: Int = 2 * 1_024 * 1_024) {
        self.fileURL = fileURL
        self.maximumBytes = max(4_096, maximumBytes)
    }

    func append(_ data: Data) throws {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        }

        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }
        guard flock(handle.fileDescriptor, LOCK_EX) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { flock(handle.fileDescriptor, LOCK_UN) }

        let currentSize = Int(try handle.seekToEnd())
        if currentSize + data.count > maximumBytes {
            try compact(handle: handle, currentSize: currentSize)
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    func read() throws -> Data {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Data() }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        guard flock(handle.fileDescriptor, LOCK_SH) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { flock(handle.fileDescriptor, LOCK_UN) }
        return try handle.readToEnd() ?? Data()
    }

    func clear() throws {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }
        guard flock(handle.fileDescriptor, LOCK_EX) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { flock(handle.fileDescriptor, LOCK_UN) }
        try handle.truncate(atOffset: 0)
        try handle.synchronize()
    }

    private func compact(handle: FileHandle, currentSize: Int) throws {
        guard currentSize > 0 else { return }
        let retainedBytes = min(currentSize, maximumBytes / 2)
        try handle.seek(toOffset: UInt64(currentSize - retainedBytes))
        var retained = try handle.readToEnd() ?? Data()
        if currentSize > retainedBytes,
           let newline = retained.firstIndex(of: 0x0A) {
            retained = Data(retained[retained.index(after: newline)...])
        }
        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: retained)
    }
}

/// File locking and fsync must never hold the UI or a Network Extension
/// callback. Bound queued work so a stalled disk cannot grow memory forever.
final class DesktopDiagnosticTraceWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.holdfast.diagnostic-trace", qos: .utility)
    private let capacity: DispatchSemaphore

    init(maximumPendingWrites: Int = 256) {
        capacity = DispatchSemaphore(value: max(1, maximumPendingWrites))
    }

    @discardableResult
    func enqueue(_ operation: @escaping @Sendable () -> Void) -> Bool {
        guard capacity.wait(timeout: .now()) == .success else { return false }
        queue.async { [self] in
            defer { capacity.signal() }
            operation()
        }
        return true
    }

    func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        try queue.sync(execute: operation)
    }
}

enum DesktopDiagnosticTrace {
    private static let writer = DesktopDiagnosticTraceWriter()
    static let enabledKey = "desktop-diagnostics.trace-enabled.v1"
    static let fileName = "desktop-diagnostic-trace-v1.jsonl"

    static var isEnabled: Bool {
        guard shouldRecord() else { return false }
        guard let sharedDefaults else { return false }
        guard sharedDefaults.object(forKey: enabledKey) != nil else { return true }
        return sharedDefaults.bool(forKey: enabledKey)
    }

    /// Hostless tests can resolve the real app-group container. Never let their
    /// synthetic provider events contaminate a user's live diagnostic history.
    static func shouldRecord(
        processName: String = ProcessInfo.processInfo.processName,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil && processName != "xctest"
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            sharedDefaults?.set(true, forKey: enabledKey)
            record(
                component: "diagnostics",
                event: "trace_enabled",
                fields: runtimeEvidence()
            )
        } else {
            record(component: "diagnostics", event: "trace_disabled")
            sharedDefaults?.set(false, forKey: enabledKey)
        }
    }

    static func record(
        component: String,
        event: String,
        fields: [String: CustomStringConvertible] = [:],
        at date: Date = Date()
    ) {
        guard isEnabled else { return }
        let normalizedFields = fields.reduce(into: [String: String]()) { result, pair in
            result[normalize(pair.key, maximumLength: 80)] = normalize(
                pair.value.description,
                maximumLength: 512
            )
        }
        let traceEvent = DesktopDiagnosticTraceEvent(
            timestampMilliseconds: Int64(date.timeIntervalSince1970 * 1_000),
            process: normalize(ProcessInfo.processInfo.processName, maximumLength: 100),
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            component: normalize(component, maximumLength: 80),
            event: normalize(event, maximumLength: 120),
            fields: normalizedFields
        )
        writer.enqueue {
            guard let store else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard var data = try? encoder.encode(traceEvent) else { return }
            data.append(0x0A)
            try? store.append(data)
        }
    }

    static func exportedData() throws -> Data {
        try writer.synchronized { try store?.read() ?? Data() }
    }

    static func clear() throws {
        try writer.synchronized { try store?.clear() }
        record(component: "diagnostics", event: "trace_cleared")
    }

    static func recentEvents(in data: Data, limit: Int) -> [DesktopDiagnosticTraceEvent] {
        guard limit > 0 else { return [] }
        let decoder = JSONDecoder()
        // Decode newest first and stop at the requested count. Reports need
        // hundreds of events, not a decode of the full multi-megabyte history.
        let recent = data.split(separator: 0x0A).reversed().lazy
            .compactMap { try? decoder.decode(DesktopDiagnosticTraceEvent.self, from: Data($0)) }
            .prefix(limit)
        return Array(recent.reversed())
    }

    static func runtimeEvidence(bundle: Bundle = .main) -> [String: CustomStringConvertible] {
        let safety = MacEnforcementSafetyPersistence.snapshot(defaults: .standard)
        let extensionURL = bundle.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions")
            .appendingPathComponent("\(DesktopEnforcementConstants.webFilterExtensionIdentifier).systemextension")
        let extensionBundle = Bundle(url: extensionURL)
        return [
            "app_build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "bundle_location": bundle.bundleURL.path.hasPrefix("/Applications/") ? "applications" : "other",
            "embedded_extension_present": FileManager.default.fileExists(atPath: extensionURL.path),
            "embedded_extension_build": extensionBundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "missing",
            "blocking_disabled": safety.blockingDisabled,
            "activation_latch_present": safety.activationSafetyLatchSet
        ]
    }

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: DesktopEnforcementConstants.appGroupIdentifier)
    }

    private static var store: DesktopDiagnosticTraceFileStore? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DesktopEnforcementConstants.appGroupIdentifier
        ) else { return nil }
        return DesktopDiagnosticTraceFileStore(
            fileURL: container.appendingPathComponent(fileName, isDirectory: false)
        )
    }

    private static func normalize(_ value: String, maximumLength: Int) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(collapsed.prefix(maximumLength))
    }
}
