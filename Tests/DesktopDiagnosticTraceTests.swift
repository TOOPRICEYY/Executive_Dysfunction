import Foundation
import XCTest

final class DesktopDiagnosticTraceTests: XCTestCase {
    func testSlowTraceWriteDoesNotBlockCallerAndQueueIsBounded() {
        let writer = DesktopDiagnosticTraceWriter(maximumPendingWrites: 1)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        XCTAssertTrue(writer.enqueue {
            started.signal()
            release.wait()
        })
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(writer.enqueue { XCTFail("Full trace queue should reject this write") })
        release.signal()
        writer.synchronized {}
        XCTAssertTrue(writer.enqueue {})
        writer.synchronized {}
    }

    func testRecentEventsSkipsTruncatedTailAndReturnsChronologicalLimit() throws {
        var data = Data()
        for index in 0..<5 {
            let event = DesktopDiagnosticTraceEvent(
                timestampMilliseconds: Int64(index), process: "test", processIdentifier: 1,
                build: "test", component: "test", event: "event", fields: [:]
            )
            data.append(try JSONEncoder().encode(event))
            data.append(0x0A)
        }
        data.append(Data("{incomplete".utf8))
        XCTAssertEqual(DesktopDiagnosticTrace.recentEvents(in: data, limit: 2).map(\.timestampMilliseconds), [3, 4])
        XCTAssertTrue(DesktopDiagnosticTrace.recentEvents(in: data, limit: 0).isEmpty)
    }
    func testLiveTraceRejectsUnitTestProcesses() {
        XCTAssertFalse(DesktopDiagnosticTrace.shouldRecord(processName: "xctest"))
        XCTAssertFalse(DesktopDiagnosticTrace.shouldRecord(
            processName: "Holdfast",
            environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]
        ))
        XCTAssertTrue(DesktopDiagnosticTrace.shouldRecord(
            processName: "Holdfast",
            environment: [:]
        ))
    }

    func testAppendProducesJSONLinesAndClearRemovesThem() throws {
        let location = temporaryFileURL()
        let store = DesktopDiagnosticTraceFileStore(fileURL: location, maximumBytes: 4_096)
        let event = DesktopDiagnosticTraceEvent(
            timestampMilliseconds: 123,
            process: "Holdfast",
            processIdentifier: 42,
            build: "65",
            component: "system-extension",
            event: "request_failed",
            fields: ["error_code": "4"]
        )
        var encoded = try JSONEncoder().encode(event)
        encoded.append(0x0A)

        try store.append(encoded)
        let lines = try decodedLines(from: store.read())
        XCTAssertEqual(lines, [event])

        try store.clear()
        XCTAssertTrue(try store.read().isEmpty)
    }

    func testCompactionKeepsCompleteRecentEventsWithinBound() throws {
        let location = temporaryFileURL()
        let maximumBytes = 4_096
        let store = DesktopDiagnosticTraceFileStore(
            fileURL: location,
            maximumBytes: maximumBytes
        )

        for index in 0..<90 {
            let event = DesktopDiagnosticTraceEvent(
                timestampMilliseconds: Int64(index),
                process: "Holdfast",
                processIdentifier: 42,
                build: "65",
                component: "provider-status",
                event: "heartbeat",
                fields: ["sequence": String(index), "padding": String(repeating: "x", count: 80)]
            )
            var encoded = try JSONEncoder().encode(event)
            encoded.append(0x0A)
            try store.append(encoded)
        }

        let data = try store.read()
        let events = try decodedLines(from: data)
        XCTAssertLessThanOrEqual(data.count, maximumBytes)
        XCTAssertFalse(events.isEmpty)
        XCTAssertEqual(events.last?.fields["sequence"], "89")
        XCTAssertGreaterThan(events.first?.timestampMilliseconds ?? -1, 0)
    }

    private func decodedLines(from data: Data) throws -> [DesktopDiagnosticTraceEvent] {
        try data.split(separator: 0x0A).map {
            try JSONDecoder().decode(DesktopDiagnosticTraceEvent.self, from: Data($0))
        }
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("trace.jsonl", isDirectory: false)
    }
}
