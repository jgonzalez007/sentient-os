//
//  XCTestCase.swift
//  Sentient OS macOS Tests
//
//  Base test case for Sentient OS — provides shared utilities for all unit tests.
//  This file exists so XCTestCase subclasses work in a synchronized-file-group project.
//

//
//  XCTestCase.swift
//  Sentient OS macOS Tests
//
//  Base test case for Sentient OS — provides shared utilities for all unit tests.
//

import XCTest

/// Base test case that all Sentient OS tests inherit from.
open class SentientTestCase: XCTestCase {

    override open func setUp() {
        super.setUp()
    }

    override open func tearDown() {
        super.tearDown()
    }

    // MARK: - Helpers

    /// Assert that the given value matches the expected string pattern (PII, error messages, etc.).
    func assertMatchesPattern(_ actual: String, pattern: String,
                              file: String = #file, line: UInt = #line) {
        XCTAssertTrue(
            (try? NSRegularExpression(pattern: pattern, options: []))
                ?.firstMatch(in: actual, options: [], range: NSRange(location: 0, length: actual.utf8.count)) != nil,
            "Expected \(actual) to match pattern \(pattern)",
            file: file, line: line
        )
    }

    /// Assert that the given string does NOT contain high-risk PII.
    func assertNoPII(_ text: String, file: String = #file, line: UInt = #line) {
        XCTAssertFalse(
            (try? NSRegularExpression(pattern: #"\b(?!000|666|9\d\d)\d{3}[ -](?!00)\d{2}[ -](?!0000)\d{4}\b"#, options: []))
                ?.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf8.count)) != nil,
            "Expected no SSN-like patterns in: \(text)",
            file: file, line: line
        )
    }
}
