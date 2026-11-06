//
//  PIIScanTests.swift
//  Sentient OS macOS Tests
//
//  Tests for the deterministic PII backstop — verifies SSN, credit-card (Luhn), and
//  passport detection patterns against positive and negative test suites.
//  These are pure-function tests with no network, filesystem, or model dependencies.
//

import XCTest
@testable import Sentient_OS_macOS

final class PIIScanTests: XCTestCase {

    // MARK: - SSN Detection

    func testValidSSNPattern() {
        // Standard 3-2-4 format with dashes
        XCTAssertTrue(PIIScan.containsHighRiskPII("My SSN is 123-45-6789"))
        XCTAssertTrue(PIIScan.containsHighRiskPII("SSN: 078-05-1120"))
        XCTAssertTrue(PIIScan.containsHighRiskPII("ssn 219-09-9999 here"))

        // Space-separated variants
        XCTAssertTrue(PIIScan.containsHighRiskPII("078 05 1120"))
        XCTAssertTrue(PIIScan.containsHighRiskPII("123 45 6789"))
    }

    func testInvalidSSNPattern() {
        // Area 000
        XCTAssertFalse(PIIScan.containsHighRiskPII("000-00-0000"))

        // Area 666
        XCTAssertFalse(PIIScan.containsHighRiskPII("666-00-0000"))

        // Area 9xx
        XCTAssertFalse(PIIScan.containsHighRiskPII("900-00-0000"))

        // Group 00
        XCTAssertFalse(PIIScan.containsHighRiskPII("123-00-0000"))

        // Serial 0000
        XCTAssertFalse(PIIScan.containsHighRiskPII("123-45-0000"))
    }

    func testBareDigitsNotMatched() {
        // A bare 9-digit number should NOT match (requires separators)
        XCTAssertFalse(PIIScan.containsHighRiskPII("123456789"))
        XCTAssertFalse(PIIScan.containsHighRiskPII("ssn: 123456789"))
    }

    // MARK: - Credit Card (Luhn) Detection

    func testValidCreditCardNumber() {
        // Visa test number (Luhn valid)
        XCTAssertTrue(PIIScan.containsHighRiskPII("4539573666123456"))
        XCTAssertTrue(PIIScan.containsHighRiskPII("card: 4539-5736-6612-3456"))
        XCTAssertTrue(PIIScan.containsHighRiskPII("4539 5736 6612 3456"))

        // Mastercard test number (Luhn valid)
        XCTAssertTrue(PIIScan.containsHighRiskPII("5555555555554444"))
    }

    func testInvalidCreditCardNumber() {
        // Random numbers that are NOT Luhn valid
        XCTAssertFalse(PIIScan.containsHighRiskPII("1234567890123456"))
        XCTAssertFalse(PIIScan.containsHighRiskPII("0000000000000000"))
    }

    func testLuhnPositiveNegatives() {
        // Known Luhn-invalid strings should not trigger
        XCTAssertFalse(PIIScan.containsHighRiskPII("1111111111111117"))
    }

    // MARK: - Passport Detection

    func testValidPassportPattern() {
        // Context-gated: "passport" followed by 6-9 alphanumeric chars with a digit
        XCTAssertTrue(PIIScan.containsHighRiskPII("passport AB123456"))
        XCTAssertTrue(PIIScan.containsHighRiskPII("my passport number is X7Y8Z9A0"))
    }

    func testPassportWithoutNumberNotDetected() {
        // "passport" without a number nearby should not trigger
        XCTAssertFalse(PIIScan.containsHighRiskPII("I have a passport"))
        XCTAssertFalse(PIIScan.containsHighRiskPII("passport application pending"))
    }

    // MARK: - Edge Cases

    func testEmptyString() {
        XCTAssertFalse(PIIScan.containsHighRiskPII(""))
    }

    func testWhitespaceOnly() {
        XCTAssertFalse(PIIScan.containsHighRiskPII("   "))
    }

    func testMixedPIIShouldReturnTrue() {
        // If any PII type is detected, should return true
        XCTAssertTrue(PIIScan.containsHighRiskPII("SSN 123-45-6789"))
        XCTAssertTrue(PIIScan.containsHighRiskPII("card 4539573666123456"))
        XCTAssertTrue(PIIScan.containsHighRiskPII("passport AB123456"))
    }

    func testSafeTextNoPII() {
        // Normal text without any PII patterns
        XCTAssertFalse(PIIScan.containsHighRiskPII("Hello, my name is John."))
        XCTAssertFalse(PIIScan.containsHighRiskPII("The meeting is at 3pm."))
        XCTAssertFalse(PIIScan.containsHighRiskPII("Please check the attached document."))
        XCTAssertFalse(PIIScan.containsHighRiskPII("Total: $1,234.56"))
    }

    func testMultiplePIIClassifications() {
        // Text with multiple PII types — should still return true (first match wins)
        XCTAssertTrue(PIIScan.containsHighRiskPII("SSN 123-45-6789 card 4539573666123456"))
    }
}
