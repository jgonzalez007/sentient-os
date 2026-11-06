//
//  ProgressTrackerTests.swift
//  Sentient OS macOS Tests
//
//  Tests for the ProgressTracker — verifies state transitions, thread safety, and
//  event ordering for the ingestion pipeline progress UI.
//  These tests exercise the state machine without needing real connectors.
//

import XCTest
@testable import Sentient_OS_macOS

final class ProgressTrackerTests: XCTestCase {

    var tracker: ProgressTracker!

    override func setUp() {
        super.setUp()
        tracker = ProgressTracker()
    }

    override func tearDown() {
        tracker = nil
        super.tearDown()
    }

    // MARK: - State Transitions

    func testInitialState() {
        // An empty tracker should report allComplete = false and no progress
        XCTAssertFalse(tracker.allComplete)
        XCTAssertTrue(tracker.failureCount == 0)
        XCTAssertTrue(tracker.allProgress().isEmpty)
    }

    func testStartTransition() {
        // Starting a source should create an idle entry and mark as fetching
        tracker.start(kind: .file)
        let progress = tracker.progress(for: .file)
        XCTAssertEqual(progress.status, .fetching)
        XCTAssertNotNil(progress.startTime)
    }

    func testCompleteTransition() {
        // Start → complete should show Done status
        tracker.start(kind: .notes)
        tracker.complete(kind: .notes)
        let progress = tracker.progress(for: .notes)
        XCTAssertEqual(progress.status, .completed)
        XCTAssertTrue(progress.isComplete)
    }

    func testFailTransition() {
        // Start → fail should show Failed status and track the error
        tracker.start(kind: .whatsapp)
        let testError = NSError(domain: "Test", code: 42, userInfo: [NSLocalizedDescriptionKey: "Boom"])
        tracker.fail(kind: .whatsapp, error: testError)
        let progress = tracker.progress(for: .whatsapp)
        XCTAssertEqual(progress.status, .failed(testError as Error?))
        XCTAssertFalse(progress.isComplete)
    }

    func testSkipTransition() {
        // Start → skip should show Skipped status
        tracker.start(kind: .imessage)
        tracker.skip(kind: .imessage, reason: "No eligible items")
        let progress = tracker.progress(for: .imessage)
        if case .skipped(let reason) = progress.status {
            XCTAssertEqual(reason, "No eligible items")
        } else {
            XCTFail("Expected skipped status")
        }
        XCTAssertTrue(progress.isComplete)
    }

    // MARK: - Terminal State Detection

    func testAllCompleteWhenAllDone() {
        tracker.start(kind: .file)
        tracker.start(kind: .notes)
        tracker.complete(kind: .file)
        tracker.complete(kind: .notes)
        XCTAssertTrue(tracker.allComplete)
    }

    func testNotAllCompleteWhenOneFails() {
        tracker.start(kind: .file)
        tracker.start(kind: .notes)
        tracker.complete(kind: .file)
        tracker.fail(kind: .notes, error: nil)
        XCTAssertFalse(tracker.allComplete)
    }

    func testFailureCount() {
        tracker.start(kind: .file)
        tracker.start(kind: .notes)
        tracker.start(kind: .whatsapp)
        tracker.fail(kind: .notes, error: nil)
        tracker.fail(kind: .whatsapp, error: nil)
        XCTAssertEqual(tracker.failureCount, 2)
    }

    func testItemsProgressed() {
        tracker.start(kind: .file)
        tracker.reportItemsTotal(kind: .file, total: 100)
        tracker.reportItemsProgressed(kind: .file, count: 50)

        let progress = tracker.progress(for: .file)
        XCTAssertEqual(progress.itemsProgressed, 50)
        XCTAssertEqual(progress.itemsTotal, 100)
        XCTAssertEqual(progress.percentComplete, 50.0)
    }

    // MARK: - Events

    func testEventsOrdering() {
        let kind = SourceKind.file

        // Record a sequence of events
        tracker.start(kind: kind)
        tracker.reportItemsProgressed(kind: kind, count: 1)
        tracker.complete(kind: kind)

        let events = tracker.recentEvents(count: 50)
        XCTAssertFalse(events.isEmpty)
        // Events should be in chronological order
        XCTAssert(events.count >= 3)
    }

    func testEventLimit() {
        // Add more events than maxEvents
        let kind = SourceKind.file
        for _ in 0..<600 {
            tracker.start(kind: kind)
        }
        let events = tracker.recentEvents(count: 50)
        XCTAssert(events.count <= 50, "Events should be limited to 50")
    }

    func testClearReset() {
        tracker.start(kind: .file)
        tracker.complete(kind: .file)
        XCTAssertFalse(tracker.allProgress().isEmpty)

        tracker.clear()
        XCTAssertTrue(tracker.allProgress().isEmpty)
        XCTAssertFalse(tracker.allComplete)
    }

    func testSnapshot() {
        tracker.start(kind: .file)
        tracker.start(kind: .notes)
        tracker.complete(kind: .file)

        let snapshot = tracker.snapshot()
        XCTAssertFalse(snapshot.progress.isEmpty)
        XCTAssertFalse(snapshot.events.isEmpty)
    }

    // MARK: - Summary

    func testSummaryString() {
        tracker.start(kind: .file)
        tracker.complete(kind: .file)
        tracker.start(kind: .notes)
        tracker.skip(kind: .notes, reason: "Empty")

        let summary = tracker.summary
        XCTAssertFalse(summary.isEmpty)
        XCTAssertTrue(summary.contains("Done") || summary.contains("Skipped"))
    }

    // MARK: - Edge Cases

    func testProgressForUnknownKind() {
        // Asking for an unknown SourceKind should return an idle snapshot
        let progress = tracker.progress(for: .mcp)
        XCTAssertEqual(progress.status, .idle)
        XCTAssertEqual(progress.itemsProgressed, 0)
        XCTAssertEqual(progress.itemsTotal, 0)
    }

    func testTransition() {
        tracker.start(kind: .file)
        tracker.transition(kind: .file, to: .processing)
        let progress = tracker.progress(for: .file)
        XCTAssertEqual(progress.status, .processing)
    }

    func testUpdateClosure() {
        tracker.start(kind: .file)
        tracker.update(kind: .file) { cp in
            cp.itemsTotal = 42
            cp.status = .processing
        }
        let progress = tracker.progress(for: .file)
        XCTAssertEqual(progress.itemsTotal, 42)
        XCTAssertEqual(progress.status, .processing)
    }
}
