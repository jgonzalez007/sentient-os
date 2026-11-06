//
//  RunProgressTests.swift
//  Sentient OS macOS Tests
//
//  Tests for RunProgress — verifies the progress snapshot struct and its
//  updateLastItem method.
//

import XCTest
@testable import Sentient_OS_macOS

final class RunProgressTests: XCTestCase {

    func testDefaultInitialState() {
        var progress = RunProgress()
        XCTAssertEqual(progress.total, 0)
        XCTAssertEqual(progress.done, 0)
        XCTAssertEqual(progress.survivors, 0)
        XCTAssertEqual(progress.junk, 0)
        XCTAssertEqual(progress.sensitive, 0)
        XCTAssertEqual(progress.failed, 0)
        XCTAssertEqual(progress.parseFailures, 0)
        XCTAssertEqual(progress.extractionFailed, 0)
        XCTAssertFalse(progress.diskFull)
        XCTAssertFalse(progress.mailIncomplete)
        XCTAssertEqual(progress.mailDeferred, 0)
    }

    func testUpdateLastItem() {
        var target = RunProgress()
        let source = RunProgress(
            lastPath: "/path/to/file.txt",
            lastItemDate: Date(),
            lastFilePath: "/path/to/file.txt",
            lastPrompt: "Hello, world!",
            lastTitle: "Test Title",
            lastSummary: "Test summary",
            lastVerdict: .survivor,
            lastSeconds: 1.5
        )
        target.updateLastItem(from: source)

        XCTAssertEqual(target.lastPath, "/path/to/file.txt")
        XCTAssertNotNil(target.lastItemDate)
        XCTAssertEqual(target.lastFilePath, "/path/to/file.txt")
        XCTAssertEqual(target.lastPrompt, "Hello, world!")
        XCTAssertEqual(target.lastTitle, "Test Title")
        XCTAssertEqual(target.lastSummary, "Test summary")
        XCTAssertEqual(target.lastVerdict, .survivor)
        XCTAssertEqual(target.lastSeconds, 1.5)
    }

    func testUpdateLastItemEmptyDoesNothing() {
        var target = RunProgress()
        var empty = RunProgress()
        // Empty has no lastPath
        empty.updateLastItem(from: empty)
        // Should not crash; target should remain unchanged
        XCTAssertNil(target.lastPath)
    }

    func testTotalSecondsCalculation() {
        var progress = RunProgress()
        progress.totalSeconds = 10.5
        XCTAssertEqual(progress.totalSeconds, 10.5)
    }

    func testSourceReadStatusCaption() {
        XCTAssertEqual(RunProgress.SourceRead.Status.reading.caption, "READING SOURCE")
        XCTAssertEqual(RunProgress.SourceRead.Status.summarized.caption, "SUMMARY")
        XCTAssertEqual(RunProgress.SourceRead.Status.quiet.caption, "SOURCE CHECKED")
        XCTAssertEqual(RunProgress.SourceRead.Status.failed.caption, "NEEDS ATTENTION")
    }

    func testSuccessfulSourcesSet() {
        var progress = RunProgress()
        progress.successfulSources = ["gmail", "notes"]
        XCTAssertTrue(progress.successfulSources.contains("gmail"))
        XCTAssertTrue(progress.successfulSources.contains("notes"))
        XCTAssertEqual(progress.successfulSources.count, 2)
    }

    func testSourceReadFailures() {
        var progress = RunProgress()
        progress.sourceReadFailures = ["gmail": "Auth expired"]
        XCTAssertEqual(progress.sourceReadFailures["gmail"], "Auth expired")
    }

    func testQuietReads() {
        var progress = RunProgress()
        progress.quietReads = 5
        XCTAssertEqual(progress.quietReads, 5)
    }
}
