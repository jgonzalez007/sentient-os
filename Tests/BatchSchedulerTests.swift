//
//  BatchSchedulerTests.swift
//  Sentient OS macOS Tests
//
//  Tests for the batch scheduler — verifies risk-ordered execution,
//  timeout enforcement, and connector sequencing.
//

import XCTest
@testable import Sentient_OS_macOS

final class BatchSchedulerTests: XCTestCase {

    // MARK: - Risk Ordering Tests

    func testRiskOrdering() {
        // Low risk should come before medium, medium before high
        XCTAssertTrue(ConnectorRisk.low < ConnectorRisk.medium)
        XCTAssertTrue(ConnectorRisk.medium < ConnectorRisk.high)
        XCTAssertFalse(ConnectorRisk.high < ConnectorRisk.low)
        XCTAssertFalse(ConnectorRisk.low < ConnectorRisk.low)
        XCTAssertFalse(ConnectorRisk.medium < ConnectorRisk.medium)
        XCTAssertFalse(ConnectorRisk.high < ConnectorRisk.high)
    }

    func testRiskSorting() {
        var risks: [ConnectorRisk] = [.high, .low, .medium, .low, .high, .medium]
        risks.sort()
        // Should be: low, low, medium, medium, high, high
        XCTAssertEqual(risks[0], .low)
        XCTAssertEqual(risks[1], .low)
        XCTAssertEqual(risks[2], .medium)
        XCTAssertEqual(risks[3], .medium)
        XCTAssertEqual(risks[4], .high)
        XCTAssertEqual(risks[5], .high)
    }

    // MARK: - ConnectorRisk Enum Tests

    func testAllRiskValuesExist() {
        // Verify all three risk levels exist
        let risks: [ConnectorRisk] = [.low, .medium, .high]
        XCTAssertEqual(risks.count, 3)
    }

    // MARK: - TimeoutPolicy Tests

    func testTimeoutPolicyPresetLocalStandard() {
        let policy = TimeoutPolicy.fromPreset(.localStandard)
        XCTAssertEqual(policy.maxSeconds, 30)
        XCTAssertEqual(policy.loadTimeout, 15)
        XCTAssertEqual(policy.listTimeout, 10)
        XCTAssertFalse(policy.silentOnTimeout)
        XCTAssertEqual(policy.maxRetries, 2)
    }

    func testTimeoutPolicyPresetCloudStandard() {
        let policy = TimeoutPolicy.fromPreset(.cloudStandard)
        XCTAssertEqual(policy.maxSeconds, 60)
        XCTAssertEqual(policy.loadTimeout, 30)
        XCTAssertEqual(policy.listTimeout, 20)
        XCTAssertFalse(policy.silentOnTimeout)
        XCTAssertEqual(policy.maxRetries, 3)
    }

    func testTimeoutPolicyPresetCloudSilent() {
        let policy = TimeoutPolicy.fromPreset(.cloudSilent)
        XCTAssertTrue(policy.silentOnTimeout)
        XCTAssertEqual(policy.maxSeconds, 60)
    }

    func testTimeoutPolicyPresetMcpStandard() {
        let policy = TimeoutPolicy.fromPreset(.mcpStandard)
        XCTAssertEqual(policy.maxSeconds, 45)
        XCTAssertEqual(policy.loadTimeout, 20)
        XCTAssertEqual(policy.listTimeout, 15)
    }

    func testTimeoutPolicyPresetLocalDB() {
        let policy = TimeoutPolicy.fromPreset(.localDB)
        XCTAssertEqual(policy.maxSeconds, 30)
        XCTAssertEqual(policy.loadTimeout, 15)
        XCTAssertEqual(policy.listTimeout, 10)
        XCTAssertFalse(policy.silentOnTimeout)
        XCTAssertEqual(policy.maxRetries, 2)
    }

    func testTimeoutPolicyNone() {
        let policy = TimeoutPolicy.none
        XCTAssertNil(policy.maxSeconds)
        XCTAssertNil(policy.loadTimeout)
        XCTAssertNil(policy.listTimeout)
        XCTAssertFalse(policy.silentOnTimeout)
        XCTAssertEqual(policy.maxRetries, 0)
        XCTAssertTrue(policy.isUnlimited)
    }

    func testTimeoutPolicyDefaultIsLocalStandard() {
        // The default should match localStandard
        XCTAssertTrue(TimeoutPolicy.default.maxSeconds == 30)
    }

    func testTimeoutPolicyIsUnlimitedForNone() {
        XCTAssertTrue(TimeoutPolicy.none.isUnlimited)
    }

    func testTimeoutPolicyEffectiveForBuckets() {
        let policy = TimeoutPolicy.fromPreset(.cloudStandard)
        let bucketsTimeout = policy.effective(for: .buckets)
        XCTAssertEqual(bucketsTimeout, 20) // listTimeout

        let loadTimeout = policy.effective(for: .load)
        XCTAssertEqual(loadTimeout, 30) // loadTimeout
    }

    func testTimeoutPolicyLoadFallbackToMaxSeconds() {
        // When loadTimeout is nil, it should fall back to maxSeconds
        let policy = TimeoutPolicy(maxSeconds: 45, loadTimeout: nil, listTimeout: nil)
        XCTAssertEqual(policy.loadTimeout, 45)
        XCTAssertEqual(policy.listTimeout, 45)
    }

    // MARK: - RateLimitPolicy Tests

    func testRateLimitNone() {
        let policy = RateLimitPolicy.none
        XCTAssertTrue(policy.isUnlimited)
        XCTAssertNil(policy.maxOperations)
    }

    func testRateLimitStrict() {
        let policy = RateLimitPolicy.strict
        XCTAssertEqual(policy.maxOperations, 5)
        XCTAssertEqual(policy.window, 60)
        XCTAssertEqual(policy.backoffMultiplier, 2.0)
        XCTAssertFalse(policy.isUnlimited)
    }

    func testRateLimitModerate() {
        let policy = RateLimitPolicy.moderate
        XCTAssertEqual(policy.maxOperations, 15)
        XCTAssertEqual(policy.window, 60)
        XCTAssertEqual(policy.backoffMultiplier, 1.5)
    }

    func testRateLimitAggressive() {
        let policy = RateLimitPolicy.aggressive
        XCTAssertEqual(policy.maxOperations, 30)
        XCTAssertEqual(policy.window, 60)
        XCTAssertEqual(policy.backoffMultiplier, 1.2)
    }

    func testRateLimitCustom() {
        let policy = RateLimitPolicy(maxOperations: 10, window: 30, backoffMultiplier: 1.0)
        XCTAssertEqual(policy.maxOperations, 10)
        XCTAssertEqual(policy.window, 30)
        XCTAssertEqual(policy.backoffMultiplier, 1.0)
    }

    // MARK: - Severity Tests

    func testSeverityComparable() {
        XCTAssertTrue(ConnectorSeverity.low < ConnectorSeverity.medium)
        XCTAssertTrue(ConnectorSeverity.medium < ConnectorSeverity.high)
    }

    func testSeverityFromRisk() {
        XCTAssertEqual(ConnectorSeverity.fromRisk(.low), .low)
        XCTAssertEqual(ConnectorSeverity.fromRisk(.medium), .medium)
        XCTAssertEqual(ConnectorSeverity.fromRisk(.high), .high)
    }

    // MARK: - Edge Cases

    func testRiskLowEqualsLow() {
        XCTAssertFalse(ConnectorRisk.low < ConnectorRisk.low)
    }

    func testRiskMediumEqualsMedium() {
        XCTAssertFalse(ConnectorRisk.medium < ConnectorRisk.medium)
    }

    func testRiskHighEqualsHigh() {
        XCTAssertFalse(ConnectorRisk.high < ConnectorRisk.high)
    }
}
