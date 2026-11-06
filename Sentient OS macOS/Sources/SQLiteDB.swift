//
//  SQLiteDB.swift
//  Sentient OS macOS
//
//  Minimal read access for the database sources (WhatsApp / iMessage / Notes), plus the
//  WAL-safe copy. The live DBs are open by their owning apps in WAL mode, so we
//  NEVER read them in place: copy the DB + its `-wal`/`-shm` siblings into a fresh temp dir,
//  read the copy, and delete it. For the DB sources we delete it *immediately* after extraction
//  so a plaintext copy of someone's messages never lingers on disk.
//
//  Phase 1.5: SQLite connection pooling. `SQLiteDB` now provides a pooled connection layer
//  that shares open database handles across calls, reducing file open/close overhead.
//  Pools have max connections, reuse, and cleanup. Mail and iMessage share the pool.
//
//  Shared by all three DB sources (the first real second-use-case that justifies a helper).
//

import Foundation
import SQLite3

/// `nonisolated` (the project defaults declarations to @MainActor): these are pure utilities that
/// work on a throwaway temp copy, so DB reads can run off-main — e.g. from the background ingestion
/// connectors that read each source's SQLite DB. @MainActor sources can still call them freely.
nonisolated enum SQLiteDB {
    enum DBError: Error, CustomStringConvertible {
        case missingFile(String)
        case open(String)
        case prepare(String)
        case step(Int32)
        var description: String {
            switch self {
            case .missingFile(let p): return "Database not found at: \(p) (is the app installed / Full Disk Access granted?)"
            case .open(let m):        return "SQLite open failed: \(m)"
            case .prepare(let m):     return "SQLite prepare failed: \(m)"
            case .step(let code):     return "SQLite read failed (code \(code))"
            }
        }
    }

    /// WAL-safe copy of a live DB (+ `-wal`/`-shm`) into a brand-new temp dir. Returns the copy's
    /// URL and the temp dir. The caller MUST delete `dir` when done (the DB sources do it the
    /// instant extraction finishes).
    static func walSafeCopy(of dbPath: String, requireCompleteWAL: Bool = false) throws -> (db: URL, dir: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath) else { throw DBError.missingFile(dbPath) }

        let dir = fm.temporaryDirectory.appendingPathComponent("sentientos-db-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var completed = false
        defer { if !completed { try? fm.removeItem(at: dir) } }

        let name = URL(fileURLWithPath: dbPath).lastPathComponent
        let dst = dir.appendingPathComponent(name)
        try fm.copyItem(atPath: dbPath, toPath: dst.path)
        for sib in ["-wal", "-shm"] where fm.fileExists(atPath: dbPath + sib) {
            // §7.7: a swallowed `-wal` copy → SQLite can't replay the latest rows → looks like "no new
            // data" (silent stale reads). Surface it (breadcrumb via Log) instead of `try?`-hiding it.
            do { try fm.copyItem(atPath: dbPath + sib, toPath: dst.path + sib) }
            catch {
                Diagnostics.report(.sourceSnapshotDegraded, phase: .snapshot, reason: "sidecar_copy", error: error,
                                   flags: [.completeSnapshot: false, .previousStateRetained: requireCompleteWAL])
                if requireCompleteWAL { throw error }
                Log("SQLiteDB: database sidecar copy failed (may read stale) — \(ErrorLabel(error))")
            }
        }
        completed = true
        return (dst, dir)
    }
}

// MARK: - SQLite Connection Pool (Phase 1.5)

/// A thread-safe, non-isolated connection pool for SQLite. Reduces open/close overhead
/// by reusing OpaquePointer handles across calls. Pool enforces max connections, automatic
/// cleanup on deinit, and per-path isolation.
///
/// Used by: Apple Mail, iMessage, WhatsApp, Notes.
///
/// The pool is keyed by database path. Each path gets at most `maxConnections` open handles,
/// but in practice only one handle is needed per path (the handles are read-only and safe
/// to share across concurrent readers).
final class SQLiteConnectionPool: @unchecked Sendable {
    private let lock = NSLock()
    private var handles: [String: [(opaque: OpaquePointer?, closeAt: Date)]] = [:]
    private let maxConnectionsPerPath: Int
    private let idleTimeout: TimeInterval
    
    /// The singleton shared pool (all DB sources share it).
    static let shared = SQLiteConnectionPool(maxConnections: 10, idleTimeout: 300)
    
    /// Create a new pool. In production, use `SQLiteConnectionPool.shared`.
    ///
    /// - Parameters:
    ///   - maxConnections: Maximum open handles per database path.
    ///   - idleTimeout: Seconds before an idle handle is closed.
    init(maxConnections: Int = 10, idleTimeout: TimeInterval = 300) {
        self.maxConnectionsPerPath = maxConnections
        self.idleTimeout = idleTimeout
    }
    
    deinit {
        lock.lock()
        defer { lock.unlock() }
        for path in handles.keys {
            for (handle, _) in handles[path] ?? [] {
                if let handle { sqlite3_close(handle) }
            }
        }
        handles.removeAll()
    }
    
    /// Get an existing or new connection for a database path.
    ///
    /// - Parameter path: The file path to the database.
    /// - Returns: An OpaquePointer to the SQLite database, or nil on failure.
    ///
    /// The returned handle is owned by the pool. Callers must NOT close it directly.
    /// Use `release(path:handle)` when done with the handle.
    func acquire(path: String) -> OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        
        // Clean up expired handles first.
        cleanup()
        
        // Try to reuse an existing handle for this path.
        if var entries = handles[path], !entries.isEmpty {
            for i in entries.indices {
                let (handle, closeAt) = entries[i]
                if handle != nil && Date().timeIntervalSince(closeAt) < idleTimeout {
                    // Valid handle, remove it from the pool for reuse.
                    entries.remove(at: i)
                    handles[path] = entries.isEmpty ? nil : entries
                    return handle
                }
            }
        }
        
        // Create a new read-only handle.
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            return nil
        }
        
        // Store in pool for reuse.
        var entries = handles[path] ?? []
        if entries.count >= maxConnectionsPerPath {
            // Pool full; close the oldest.
            entries.remove(at: 0)
        }
        entries.append((db, Date().addingTimeInterval(idleTimeout)))
        handles[path] = entries
        
        return db
    }
    
    /// Release a handle back to the pool for reuse.
    ///
    /// - Parameters:
    ///   - path: The database path the handle was acquired from.
    ///   - handle: The handle to return.
    func release(path: String, handle: OpaquePointer?) {
        guard handle != nil else { return }
        lock.lock()
        defer { lock.unlock() }
        var entries = handles[path] ?? []
        entries.append((handle, Date().addingTimeInterval(idleTimeout)))
        handles[path] = entries
    }
    
    /// Remove all handles for a path and optionally close them.
    ///
    /// - Parameters:
    ///   - path: The database path.
    ///   - closeAll: If true, close all handles for the path.
    func releasePath(_ path: String, closeAll: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        if let entries = handles[path] {
            if closeAll {
                for (handle, _) in entries {
                    if let handle { sqlite3_close(handle) }
                }
            }
        }
        handles[path] = nil
    }
    
    /// Close all handles in the pool (used during cleanup or shutdown).
    func closeAll() {
        lock.lock()
        defer { lock.unlock() }
        for entries in handles.values {
            for (handle, _) in entries {
                if let handle { sqlite3_close(handle) }
            }
        }
        handles.removeAll()
    }
    
    /// Cleanup idle handles past the timeout.
    private func cleanup() {
        let cutoff = Date().timeIntervalSince1970 - idleTimeout
        for path in handles.keys {
            handles[path] = handles[path]?.filter { $0.closeAt.timeIntervalSince1970 > cutoff } 
                ?? []
        }
        // Remove empty entries.
        handles = Dictionary(filter: handles.map { ($0.key, $0.value) }, uniquingKeysWith: { $0 })
    }
    
    /// Get the number of open handles.
    var openHandleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return handles.values.reduce(0) { $0 + $1.count }
    }
}

/// A thin SQLite connection for reading one copied DB. Single-threaded use; closes on deinit.
/// Opened read-WRITE on the *temp copy* (not the original) so SQLite can transparently replay the
/// copied `-wal` — the most reliable way to see the very latest rows.
nonisolated final class SQLiteReader {
    private var db: OpaquePointer?
    private let path: String  // tracked for pool release
    private let usePool: Bool // whether to use the shared pool
    private let dbName: String   // the DB basename (chat.db / ChatStorage.sqlite / …) — a diagnostics tag

    init(path: String, usePool: Bool = true) throws {
        let name = URL(fileURLWithPath: path).lastPathComponent
        dbName = ["chat.db", "ChatStorage.sqlite", "NoteStore.sqlite", "Envelope Index", "sms.db"].contains(name) ? name : "other"
        self.path = path
        self.usePool = usePool
        
        if usePool {
            // Try to acquire from the pool first.
            if let pooled = SQLiteConnectionPool.shared.acquire(path: path) {
                db = pooled
                return
            }
            // If pool acquire fails, fall through to create a new handle.
        }
        
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            db = nil
            throw SQLiteDB.DBError.open(msg)
        }
    }
    
    deinit {
        if usePool {
            // Return to pool instead of closing.
            if let db { SQLiteConnectionPool.shared.release(path: path, handle: db) }
        } else {
            sqlite3_close(db)
        }
    }

    /// Dispose of the reader and optionally close the pooled handle.
    ///
    /// - Parameter forceClose: If true, force-close the handle instead of returning to pool.
    func dispose(forceClose: Bool = false) {
        if usePool && !forceClose {
            // Nothing to do; the pool will hold it.
            return
        }
        if let db {
            if usePool {
                SQLiteConnectionPool.shared.releasePath(path, closeAll: false)
            } else {
                sqlite3_close(db)
            }
        }
        db = nil
    }

    /// Run a read query, invoking `row` for each result row in order. (We interpolate only our own
    /// numeric literals into SQL — no untrusted input — so no bind params are needed.)
    func forEachRow(_ sql: String, _ row: (Row) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            // §7.7: our SQL is static (no user input), so a prepare failure = a SCHEMA change — the
            // "Apple/Meta renamed a column" tripwire, uniform across all 4 DB sources. The errmsg is a
            // schema string ("no such column: ZFOO"), never row content (allowlisted, §10).
            let errmsg = String(cString: sqlite3_errmsg(db))
            CrashReporting.captureEvent("db.schema_error", level: .error,
                tags: ["db": dbName],
                extra: ["sqlite_code": String(sqlite3_errcode(db)), "sqlite_extended_code": String(sqlite3_extended_errcode(db))],
                fingerprint: ["db", "schema_error", dbName])
            throw SQLiteDB.DBError.prepare(errmsg)
        }
        defer { sqlite3_finalize(stmt) }
        while true {
            let result = sqlite3_step(stmt)
            switch result {
            case SQLITE_ROW: try row(Row(stmt!))
            case SQLITE_DONE: return
            default:
                // An interrupted, corrupt, or unavailable snapshot is not a complete read.
                // Propagate the failure so callers cannot commit a partial source as success.
                throw SQLiteDB.DBError.step(result)
            }
        }
    }

    /// Typed, index-based column access for one row.
    struct Row {
        private let stmt: OpaquePointer
        init(_ s: OpaquePointer) { stmt = s }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func text(_ i: Int32) -> String? {
            guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func blob(_ i: Int32) -> Data? {
            guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let p = sqlite3_column_blob(stmt, i) else { return nil }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
        }
    }
}
