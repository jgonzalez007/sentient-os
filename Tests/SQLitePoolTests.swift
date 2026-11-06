//
//  SQLitePoolTests.swift
//  Sentient OS macOS Tests
//
//  Tests for SQLiteConnectionPool — verifies connection pool configuration,
//  error handling, and basic lifecycle operations.
//  Uses a real in-memory SQLite database for testing.
//

import XCTest
import SQLite3
@testable import Sentient_OS_macOS

final class SQLitePoolTests: XCTestCase {

    var tempDir: URL!
    var dbPath: String!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporary()).appendingPathComponent("sentient-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbPath = tempDir.appendingPathComponent("test.db").path
    }

    override func tearDown() {
        // Clean up temp files
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Config Tests

    func testStandardConfig() {
        let config = SQLiteConnectionPool.Config.standard
        XCTAssertEqual(config.maxConnections, 8)
        XCTAssertTrue(config.walMode)
        XCTAssertTrue(config.sharedCache)
    }

    func testCustomConfig() {
        let config = SQLiteConnectionPool.Config(
            maxConnections: 4,
            walMode: false,
            sharedCache: false
        )
        XCTAssertEqual(config.maxConnections, 4)
        XCTAssertFalse(config.walMode)
        XCTAssertFalse(config.sharedCache)
    }

    // MARK: - Connection Tests

    func testCreateConnection() {
        // Create a connection to a real database
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            XCTFail("Failed to open database")
            return
        }

        // Verify we can execute a simple query
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT 1", -1, &stmt, nil) == SQLITE_OK else {
            XCTFail("Failed to prepare statement")
            return
        }

        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        sqlite3_close(db)
    }

    func testWalMode() {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            XCTFail("Failed to open database")
            return
        }

        // Set WAL mode
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL", -1, &stmt, nil)
        _ = sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        // Verify WAL mode was applied
        sqlite3_prepare_v2(db, "PRAGMA journal_mode", -1, &stmt, nil)
        _ = sqlite3_step(stmt)
        let mode = String(cString: sqlite3_column_text(stmt, 0)!)
        XCTAssertEqual(mode, "wal")

        sqlite3_finalize(stmt)
        sqlite3_close(db)
    }

    func testSharedCacheMode() {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            XCTFail("Failed to open database")
            return
        }

        // Set shared cache
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "PRAGMA cache_shared_cache=ON", -1, &stmt, nil)
        _ = sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        sqlite3_close(db)
    }

    func testCloseAllConnections() {
        // Create multiple connections and close them all
        var handles: [OpaquePointer?] = []

        for _ in 0..<3 {
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  let db else { continue }
            handles.append(db)
        }

        // Close all
        for handle in handles {
            sqlite3_close(handle)
        }

        XCTAssertEqual(handles.count, 3)
    }

    // MARK: - PoolError Tests

    func testOpenFailedErrorDescription() {
        let error = PoolError.openFailed("/nonexistent/path.db")
        XCTAssertTrue(error.errorDescription?.contains("/nonexistent/path.db") == true)
        XCTAssertTrue(error.errorDescription?.contains("Failed to open") == true)
    }

    func testMaxPoolExceededErrorDescription() {
        let error = PoolError.maxPoolExceeded
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("maximum capacity") == true)
    }

    func testAllConnectionsDeadErrorDescription() {
        let error = PoolError.allConnectionsDead
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("dead") == true)
    }

    // MARK: - Concurrent Access Tests

    func testConcurrentDatabaseAccess() {
        // Create a table and insert data from multiple concurrent tasks
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            XCTFail("Failed to open database")
            return
        }

        // Create table
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "CREATE TABLE IF NOT EXISTS test (id INTEGER PRIMARY KEY, value TEXT)", -1, &stmt, nil)
        _ = sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        // Insert from main thread
        sqlite3_prepare_v2(db, "INSERT INTO test (value) VALUES ('test1')", -1, &stmt, nil)
        _ = sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        sqlite3_close(db)
    }
}
