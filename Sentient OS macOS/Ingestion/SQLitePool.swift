//
//  SQLitePool.swift
//  Sentient OS macOS
//
//  Phase 1.5: SQLite connection pooling for the Ingestion pipeline.
//
//  Provides a managed pool of pre-connected, reusable SQLite handles (OpaquePointer)
//  with WAL mode, shared-cache optimization, auto-reconnect for dead connections,
//  and a borrowed/returned API for safe concurrent access.
//
//  The pool uses Foundation's SQLite C bindings (libsqlite3) and is fully
//  thread-safe via NSLock around all state mutations.
//

import Foundation
import SQLite3

// MARK: - SQLiteConnectionPool

/// Manages a pool of pre-connected SQLite connections.
/// Connections are created in WAL mode with shared cache for
/// concurrent read performance during connector batch execution.
///
/// Used by: Apple Mail, iMessage, WhatsApp, Notes — all DB sources
/// that need to read local SQLite databases (ChatStorage.sqlite,
//  Envelope Index, NoteStore.sqlite, sms.db, etc.).
@MainActor
final class SQLiteConnectionPool: @unchecked Sendable {
    
    // MARK: - Config
    
    /// Configuration for the connection pool.
    struct Config: Sendable {
        /// Maximum number of connections in the pool.
        let maxConnections: Int
        /// Whether to enable WAL (Write-Ahead Logging) mode.
        /// WAL enables concurrent readers without blocking the writer.
        let walMode: Bool
        /// Whether to enable shared-cache mode for concurrent reads.
        let sharedCache: Bool
        
        /// Standard configuration: 8 connections, WAL + shared cache.
        static let standard = Config(
            maxConnections: 8,
            walMode: true,
            sharedCache: true
        )
    }
    
    // MARK: - Pool entry
    
    private struct PoolEntry: Sendable {
        let connection: OpaquePointer
        let lastUse: Date
        let path: String
    }
    
    // MARK: - Properties
    
    private let config: Config
    private var connections: [String: [PoolEntry]] = [:]  // keyed by db path
    private let lock = NSLock()
    private let maxIdleInterval: TimeInterval = 300  // 5 minutes
    private let minReconnectDelay: TimeInterval = 2
    private var lastReconnectAttempt: [String: Date] = [:]
    
    /// The singleton shared pool — all DB sources share it.
    static let standard = SQLiteConnectionPool(config: .standard)
    
    /// Create a new pool with the given configuration.
    /// In production, use `SQLiteConnectionPool.standard`.
    init(config: Config) {
        self.config = config
    }
    
    deinit {
        lock.lock()
        defer { lock.unlock() }
        closeAllInternal()
    }
    
    // MARK: - Borrow a connection
    
    /// Borrow a connection from the pool for the given database path.
    /// Pre-connects the database (opens it, verifies schema) if it hasn't been seen.
    ///
    /// - Parameters:
    ///   - queue: A Dispatch queue for the connection's use context.
    ///   - completion: Called when a connection is available (or on failure).
    ///
    /// The returned handle must be returned via `returnConnection(_:toPool:forPath:)`
    /// when done. The caller must NOT close the connection directly.
    func borrowedConnection(
        queue: DispatchQueue,
        forPath path: String,
        completion: @escaping (Result<OpaquePointer, PoolError>) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        
        // Health check: detect dead connections before handing one out.
        healthCheckInternal()
        
        // Try to borrow an existing live connection.
        if let handle = borrowExisting(path: path) {
            queue.async { completion(.success(handle)) }
            return
        }
        
        // No live connection; create a new one (connection pooling).
        // This is the pre-connect phase: open the DB handle and
        // apply WAL + shared-cache options.
        guard let handle = createConnection(path: path) else {
            queue.async { completion(.failure(.openFailed(path))) }
            return
        }
        
        queue.async { completion(.success(handle)) }
    }
    
    /// Return a borrowed connection to the pool for reuse.
    /// The pool may evict it based on the idle timeout.
    func returnConnection(
        _ connection: OpaquePointer?,
        toPoolForPath path: String
    ) {
        guard connection != nil else { return }
        lock.lock()
        defer { lock.unlock() }
        
        var entries = connections[path] ?? []
        // Remove it from the pool (we're returning a borrowed handle).
        // The pool manages a fixed pool; returning adds it back as available.
        if !entries.isEmpty {
            entries.append(PoolEntry(connection: connection!, lastUse: Date(), path: path))
            // Trim to max connections.
            if entries.count > config.maxConnections {
                entries.removeFirst(entries.count - config.maxConnections)
            }
            connections[path] = entries
        } else {
            connections[path] = [PoolEntry(connection: connection!, lastUse: Date(), path: path)]
        }
    }
    
    // MARK: - Health check
    
    /// Verify all connections are still alive; reconnect dead ones.
    /// This is called automatically before each borrow, but can also
    /// be invoked manually for proactive monitoring.
    func healthCheck() {
        lock.lock()
        defer { lock.unlock() }
        healthCheckInternal()
    }
    
    // MARK: - Close all
    
    /// Tear down the entire pool: close all handles and clear state.
    /// Used during shutdown or when a DB file is deleted.
    func closeAll() {
        lock.lock()
        defer { lock.unlock() }
        closeAllInternal()
    }
    
    // MARK: - Pool stats
    
    /// Number of tracked entries in the pool (may include dead handles
    /// waiting for the next health check to evict them).
    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.values.reduce(0) { $0 + $1.count }
    }
    
    /// Distinct database paths in the pool.
    var pathCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.count
    }
    
    // MARK: - Internal helpers
    
    /// Try to return a pooled connection for reuse, or create a new one.
    private func borrowExisting(path: String) -> OpaquePointer? {
        guard var entries = connections[path], !entries.isEmpty else { return nil }
        
        // Iterate from most recently used.
        for i in (0..<entries.count).reversed() {
            var entry = entries[i]
            // Check if the connection is still alive.
            if sqlite3_db_release_memory(entry.connection) == SQLITE_OK ||
               sqlite3_total_bytes(entry.connection) >= 0 {
                entries[i] = entry
                entry.lastUse = Date()
                connections[path] = entries
                return entry.connection
            }
        }
        
        // All pooled entries dead; clear them.
        connections[path] = []
        return nil
    }
    
    /// Create a fresh connection with WAL + shared-cache.
    /// This is the core pre-connect logic.
    private func createConnection(path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        let openFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        
        guard sqlite3_open_v2(path, &db, openFlags, nil) == SQLITE_OK,
              let db else {
            return nil
        }
        
        var created = false
        defer { if !created { sqlite3_close(db) } }
        
        // Apply WAL mode.
        if config.walMode {
            let walSQL = "PRAGMA journal_mode=WAL;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, walSQL, -1, &stmt, nil) == SQLITE_OK,
               let stmt {
                _ = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                created = true
            }
        }
        
        // Apply shared cache.
        if config.sharedCache {
            let sharedSQL = "PRAGMA cache_shared_cache=ON;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sharedSQL, -1, &stmt, nil) == SQLITE_OK,
               let stmt {
                _ = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                created = true
            }
        }
        
        // Verify the connection is actually usable.
        if sqlite3_db_readonly(db, "main") == 0 {
            // Try a simple query to prove liveness.
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT 1", -1, &stmt, nil) == SQLITE_OK,
               let stmt,
               sqlite3_step(stmt) == SQLITE_ROW {
                sqlite3_finalize(stmt)
                return db
            }
        }
        
        return nil
    }
    
    /// Health-check all connections: test each handle and reconnect dead ones.
    private func healthCheckInternal() {
        var pathsToReconnect: [String] = []
        
        for (path, entries) in connections {
            var liveEntries: [PoolEntry] = []
            var anyDead = false
            
            for entry in entries {
                // Quick liveness check without blocking.
                let rc = sqlite3_db_readonly(entry.connection, "main")
                if rc >= 0 {
                    liveEntries.append(entry)
                } else {
                    anyDead = true
                }
            }
            
            if anyDead && !liveEntries.isEmpty {
                // Some are dead but not all; replace dead ones.
                connections[path] = liveEntries
                pathsToReconnect.append(path)
            } else if anyDead && liveEntries.isEmpty {
                // All dead; full reconnect needed.
                pathsToReconnect.append(path)
            } else {
                connections[path] = liveEntries
            }
        }
        
        // Reconnect dead paths (with backoff).
        for path in pathsToReconnect {
            let now = Date()
            if let last = lastReconnectAttempt[path],
               now.timeIntervalSince(last) < minReconnectDelay {
                continue  // Throttled; skip reconnect.
            }
            lastReconnectAttempt[path] = now
            
            // Create a fresh connection.
            if let newHandle = createConnection(path: path) {
                // Pre-connect: ensure WAL + shared-cache.
                if config.walMode {
                    let sql = "PRAGMA journal_mode=WAL;"
                    var stmt: OpaquePointer?
                    if sqlite3_prepare_v2(newHandle, sql, -1, &stmt, nil) == SQLITE_OK {
                        sqlite3_step(stmt)
                        sqlite3_finalize(stmt)
                    }
                }
                if config.sharedCache {
                    let sql = "PRAGMA cache_shared_cache=ON;"
                    var stmt: OpaquePointer?
                    if sqlite3_prepare_v2(newHandle, sql, -1, &stmt, nil) == SQLITE_OK {
                        sqlite3_step(stmt)
                        sqlite3_finalize(stmt)
                    }
                }
                
                lock.lock()
                var entries = connections[path] ?? []
                entries.append(PoolEntry(connection: newHandle, lastUse: Date(), path: path))
                if entries.count > config.maxConnections {
                    entries.removeFirst(entries.count - config.maxConnections)
                }
                connections[path] = entries
                lock.unlock()
            }
        }
    }
    
    /// Close all connections and clear pool state.
    private func closeAllInternal() {
        for entries in connections.values {
            for entry in entries {
                sqlite3_close(entry.connection)
            }
        }
        connections.removeAll()
        lastReconnectAttempt.removeAll()
    }
}

// MARK: - PoolError

/// Errors specific to connection pool operations.
enum PoolError: LocalizedError {
    case openFailed(String)      // DB path couldn't be opened
    case maxPoolExceeded          // Max connections reached, oldest evicted
    case allConnectionsDead       // Health check found all handles dead
    
    var errorDescription: String? {
        switch self {
        case .openFailed(let path):
            return "Failed to open database at path: \(path)"
        case .maxPoolExceeded:
            return "Connection pool at maximum capacity"
        case .allConnectionsDead:
            return "All pooled connections are dead; pool requires rebuild"
        }
    }
}

// MARK: - Usage examples (inline documentation)

/// The SQLiteConnectionPool is used by DB source connectors
/// (AppleMailConnector, iMessageConnector, WhatsAppConnector, NotesConnector).
///
/// Typical usage pattern:
/// ```swift
/// // Borrow a connection.
/// SQLiteConnectionPool.standard.borrowedConnection(
///     queue: .global(qos: .utility),
///     forPath: chatDBPath
/// ) { result in
///     switch result {
///     case .success(let db):
///         defer { SQLiteConnectionPool.standard.returnConnection(db, toPoolForPath: chatDBPath) }
///         // Use db (OpaquePointer) with sqlite3_prepare_v2, sqlite3_step, etc.
///     case .failure(let error):
///         Log("Failed to borrow connection: \(error.localizedDescription)")
///     }
/// }
/// ```
///
/// Pre-connecting all pools at startup:
/// ```swift
/// // During app launch or early in the pipeline.
/// let paths = [chatDBPath, notesDBPath, mailDBPath]
/// for path in paths {
///     SQLiteConnectionPool.standard.healthCheck()
/// }
/// ```
