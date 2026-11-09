import Foundation
import XCTest

final class MacEnforcementSafetyPersistenceTests: XCTestCase {
    func testReceiptRoundTripsAsOneCoherentValue() throws {
        let receipt = MacEnforcementSameBootResetReceipt(
            attemptIdentifier: "reset-123",
            bootSessionIdentifier: "boot-456",
            completedAt: Date(timeIntervalSince1970: 1_800_000_000.25)
        )

        let decoded = MacEnforcementSafetyPersistence.decodeReceipt(
            from: try MacEnforcementSafetyPersistence.encode(receipt)
        )

        XCTAssertEqual(decoded, receipt)
    }

    func testMalformedReceiptIsRejected() throws {
        let malformed = MacEnforcementSameBootResetReceipt(
            attemptIdentifier: "   ",
            bootSessionIdentifier: "boot-456",
            completedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertThrowsError(try MacEnforcementSafetyPersistence.encode(malformed))
        XCTAssertNil(
            MacEnforcementSafetyPersistence.decodeReceipt(
                from: Data("not-json".utf8)
            )
        )
    }

    func testSnapshotReportsDisabledLatchAndReceiptTogether() throws {
        let suiteName = "MacEnforcementSafetyPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let receipt = MacEnforcementSameBootResetReceipt(
            attemptIdentifier: "reset-123",
            bootSessionIdentifier: "boot-456",
            completedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        defaults.set(true, forKey: MacEnforcementSafetyPersistence.blockingDisabledKey)
        defaults.set(
            "boot-456",
            forKey: MacEnforcementSafetyPersistence.activationSafetyBootSessionKey
        )
        try MacEnforcementSafetyPersistence.persist(receipt, defaults: defaults)
        defaults.set("preference-operation-timeout", forKey: MacEnforcementSafetyPersistence.activationSafetyReasonKey)
        defaults.set(1_800_000_001.0, forKey: MacEnforcementSafetyPersistence.activationSafetyTriggeredAtKey)

        let snapshot = MacEnforcementSafetyPersistence.snapshot(defaults: defaults)

        XCTAssertTrue(snapshot.blockingDisabled)
        XCTAssertTrue(snapshot.activationSafetyLatchSet)
        XCTAssertEqual(snapshot.activationSafetyBootSessionIdentifier, "boot-456")
        XCTAssertEqual(snapshot.sameBootResetReceipt, receipt)
        XCTAssertEqual(snapshot.activationSafetyReason, "preference-operation-timeout")
        XCTAssertEqual(snapshot.activationSafetyTriggeredAt, Date(timeIntervalSince1970: 1_800_000_001))
    }
}
