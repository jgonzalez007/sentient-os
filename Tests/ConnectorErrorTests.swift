//
//  ConnectorErrorTests.swift
//  Sentient OS macOS Tests
//
//  Tests for the ConnectorError taxonomy — verifies descriptions, user messages,
//  and Sentry fingerprint types for all error cases.
//  Pure data tests — no network, filesystem, or model dependencies.
//

import XCTest
@testable import Sentient_OS_macOS

final class ConnectorErrorTests: XCTestCase {

    // MARK: - fileReadError

    func testFileReadErrorDescription() {
        let error = ConnectorError.fileReadError("/path/to/file.txt")
        XCTAssertTrue(error.description.contains("/path/to/file.txt"))
        XCTAssertTrue(error.description.contains("Failed to read"))
    }

    func testFileReadErrorUserMessage() {
        let error = ConnectorError.fileReadError("/path/to/file.txt")
        XCTAssertEqual(error.userMessage, "Could not read a file. Check that it still exists and is accessible.")
    }

    func testFileReadErrorSentryType() {
        XCTAssertEqual(ConnectorError.fileReadError("").sentryType, "file_read")
    }

    // MARK: - databaseError

    func testDatabaseErrorDescription() {
        let error = ConnectorError.databaseError("chat.db", code: 5)
        XCTAssertTrue(error.description.contains("chat.db"))
        XCTAssertTrue(error.description.contains("5"))
    }

    func testDatabaseErrorUserMessage() {
        let error = ConnectorError.databaseError("chat.db", code: 5)
        XCTAssertEqual(error.userMessage, "A local database could not be accessed. Ensure Full Disk Access is granted.")
    }

    func testDatabaseErrorSentryType() {
        XCTAssertEqual(ConnectorError.databaseError("", code: 0).sentryType, "database")
    }

    // MARK: - networkError

    func testNetworkErrorDescriptionWithCode() {
        let error = ConnectorError.networkError("Gmail", code: 429)
        XCTAssertTrue(error.description.contains("Gmail"))
        XCTAssertTrue(error.description.contains("429"))
    }

    func testNetworkErrorDescriptionWithoutCode() {
        let error = ConnectorError.networkError("Slack", code: nil)
        XCTAssertTrue(error.description.contains("Slack"))
        XCTAssertFalse(error.description.contains("HTTP"))
    }

    func testNetworkErrorUserMessage() {
        let error = ConnectorError.networkError("Gmail", code: 500)
        XCTAssertEqual(error.userMessage, "A cloud connection failed. Check your internet and try again.")
    }

    func testNetworkErrorSentryType() {
        XCTAssertEqual(ConnectorError.networkError("", code: nil).sentryType, "network")
    }

    // MARK: - authExpired

    func testAuthExpiredDescription() {
        XCTAssertEqual(ConnectorError.authExpired("gmail").description, "Auth expired for gmail")
    }

    func testAuthExpiredUserMessage() {
        XCTAssertEqual(
            ConnectorError.authExpired("gmail").userMessage,
            "A cloud connection needs to be re-authenticated."
        )
    }

    func testAuthExpiredSentryType() {
        XCTAssertEqual(ConnectorError.authExpired("").sentryType, "auth_expired")
    }

    // MARK: - invalidResponse

    func testInvalidResponseDescription() {
        let error = ConnectorError.invalidResponse("Notion", rule: "schema")
        XCTAssertTrue(error.description.contains("Notion"))
        XCTAssertTrue(error.description.contains("schema"))
    }

    func testInvalidResponseUserMessage() {
        XCTAssertEqual(
            ConnectorError.invalidResponse("Notion", rule: "schema").userMessage,
            "A cloud service returned unexpected data. Try again later."
        )
    }

    func testInvalidResponseSentryType() {
        XCTAssertEqual(ConnectorError.invalidResponse("", rule: "").sentryType, "invalid_response")
    }

    // MARK: - Storage Errors

    func testStorageErrorDescription() {
        XCTAssertEqual(ConnectorError.storageError("CycleStore").description, "Storage error in CycleStore")
    }

    func testStorageErrorUserMessage() {
        XCTAssertEqual(ConnectorError.storageError("").userMessage, "The local storage failed to save. Check available disk space.")
    }

    func testStorageErrorSentryType() {
        XCTAssertEqual(ConnectorError.storageError("").sentryType, "storage")
    }

    // MARK: - Timeout

    func testTimeoutDescription() {
        let error = ConnectorError.timeout("Apple Mail", seconds: 300.0)
        XCTAssertTrue(error.description.contains("Apple Mail"))
        XCTAssertTrue(error.description.contains("300"))
    }

    func testTimeoutUserMessage() {
        XCTAssertEqual(ConnectorError.timeout("Gmail", seconds: 60).userMessage, "A source took too long to respond. Retrying next run.")
    }

    func testTimeoutSentryType() {
        XCTAssertEqual(ConnectorError.timeout("", seconds: 0).sentryType, "timeout")
    }

    // MARK: - Parse Error

    func testParseErrorDescription() {
        let error = ConnectorError.parseError("notes", "protobuf decode")
        XCTAssertTrue(error.description.contains("notes"))
        XCTAssertTrue(error.description.contains("protobuf"))
    }

    func testParseErrorUserMessage() {
        XCTAssertEqual(ConnectorError.parseError("", "").userMessage, "A local source's data format could not be read.")
    }

    func testParseErrorSentryType() {
        XCTAssertEqual(ConnectorError.parseError("", "").sentryType, "parse")
    }

    // MARK: - Permission Denied

    func testPermissionDeniedDescription() {
        XCTAssertEqual(ConnectorError.permissionDenied("Calendar").description, "Permission denied: Calendar")
    }

    func testPermissionDeniedUserMessage() {
        XCTAssertEqual(ConnectorError.permissionDenied("Calendar").userMessage, "Permission is needed for Calendar. Check System Settings.")
    }

    func testPermissionDeniedSentryType() {
        XCTAssertEqual(ConnectorError.permissionDenied("").sentryType, "permission")
    }

    // MARK: - Other Errors

    func testCancelledDescription() {
        XCTAssertEqual(ConnectorError.cancelled("Gmail").description, "Cancelled: Gmail")
    }

    func testCancelledUserMessage() {
        XCTAssertEqual(ConnectorError.cancelled("").userMessage, "The read was cancelled.")
    }

    func testCancelledSentryType() {
        XCTAssertEqual(ConnectorError.cancelled("").sentryType, "cancelled")
    }

    func testUnsupportedSchemaDescription() {
        let error = ConnectorError.unsupportedSchema("chat.db", detail: "missing column")
        XCTAssertTrue(error.description.contains("chat.db"))
        XCTAssertTrue(error.description.contains("missing column"))
    }

    func testUnsupportedSchemaUserMessage() {
        XCTAssertEqual(
            ConnectorError.unsupportedSchema("", nil).userMessage,
            "A local source's format has changed. Updating Sentient OS may fix it."
        )
    }

    func testEmptyDescription() {
        XCTAssertEqual(ConnectorError.empty("").description, "No eligible work from ")
    }

    func testEmptyUserMessage() {
        XCTAssertEqual(ConnectorError.empty("").userMessage, "No new items to process from this source.")
    }

    func testRateLimitedDescription() {
        let error = ConnectorError.rateLimited("Gmail", retryAfter: 60.0)
        XCTAssertTrue(error.description.contains("Gmail"))
        XCTAssertTrue(error.description.contains("60"))
    }

    func testRateLimitedUserMessage() {
        XCTAssertEqual(
            ConnectorError.rateLimited("", retryAfter: 120).userMessage,
            "A cloud service is temporarily busy. Try again later."
        )
    }

    func testRateLimitedSentryType() {
        XCTAssertEqual(ConnectorError.rateLimited("", retryAfter: nil).sentryType, "rate_limited")
    }

    // MARK: - NoReadSurface

    func testNoReadSurfaceDescription() {
        XCTAssertEqual(ConnectorError.noReadSurface("direct-notion").description, "No read surface for direct-notion")
    }

    func testNoReadSurfaceUserMessage() {
        XCTAssertEqual(
            ConnectorError.noReadSurface("").userMessage,
            "A connected service has no available read tools."
        )
    }

    func testNoReadSurfaceSentryType() {
        XCTAssertEqual(ConnectorError.noReadSurface("").sentryType, "no_read_surface")
    }

    // MARK: - Sendability

    func testErrorIsSendable() {
        // ConnectorError must be Sendable for pipeline use
        let error: any Sendable = ConnectorError.networkError("test", code: nil)
        XCTAssertNotNil(error)
    }
}
