//
//  Connector.swift
//  Sentient OS macOS
//
//  The connector abstraction for the iterative system. A connector is DUMB: it lists its current
//
// Phase 1.8: Deprecated — Use `BatchScheduler.execute()` instead.
// The old `Connector.runAll()` pattern has been superseded by the risk-ordered batch scheduler.
//  work-items per BUCKET (each with an ItemKey), and loads one for the model. ALL pointer logic
//  (initial/iterative, advancing, crash-resume) lives in IterativeRun — never in a connector.
//
//  Work payload + content reuse the existing `Candidate` / `Artifact` value types (DataSource.swift):
//  a connector emits `(ItemKey, Candidate)` pairs; IterativeRun calls `load(Candidate) → Artifact →
//  Triage`. (Candidate's `cursorKey`/`cursorValue` are vestigial here — the old backfill cursor is
//  gone; only ItemKey + bucketKey matter.)
//
//  Buckets are the pointer namespace: files → "file:<root.id>" (per folder) · notes → "notes"
//  (single) · chats → "whatsapp:<jid>" / "imessage:<guid>" (per chat).
//
//  Phase 1.1: Connector v2 protocol — adds `ConnectorError` (typed errors per source),
//  `RateLimitPolicy` (per-connector rate limiting), and `TimeoutPolicy` (per-connector timeouts).
//

import Foundation

// MARK: - ConnectorError (v2 protocol)

/// Typed errors for connector operations. Replaces bare `throws Error` so IterativeRun can
/// classify failures at the call site without pattern-matching on `ErrorLabel`. Each case
/// carries just enough context for Sentry fingerprinting and the UI to show a user-friendly
/// message — never raw paths, account IDs, or tokens.
///
/// The error taxonomy was designed to cover every path through the ingestion pipeline:
/// network, storage, schema, auth, permission, timeout, and structural data failures.
/// New source-specific errors live in their source file and extend this enum via `extension`.
enum ConnectorError: Error, Sendable, CustomStringConvertible {
    /// A local file could not be read (missing, permissions, or I/O).
    case fileReadError(String)                          // e.g. "file:/path/to/file"

    /// A local SQLite database source failed (missing DB, corrupt WAL, busy).
    case databaseError(String, code: Int32)             // e.g. "chat.db", SQLITE_BUSY

    /// Network call failed or timed out (cloud connectors).
    case networkError(String, code: Int?)               // e.g. "Gmail", optional HTTP status

    /// An OAuth token is expired or the connection needs re-auth.
    case authExpired(String)                            // e.g. "gmail", "slack"

    /// A remote API returned an unexpected schema or payload.
    case invalidResponse(String, rule: String)          // e.g. "notion", "schema"

    /// The connector's read surface is missing (no tools, no tools available).
    case noReadSurface(String)                          // e.g. "direct-notion"

    /// Storage backend failed (disk full, SwiftData corrupted, write failure).
    case storageError(String)                           // e.g. "CycleStore"

    /// The source timed out (per-connector deadline exceeded).
    case timeout(String, seconds: Double)               // e.g. "Apple Mail", 300.0

    /// The source returned data in an unexpected format (decode/schema failure).
    case parseError(String, detail: String)             // e.g. "notes", "protobuf decode"

    /// Permission was denied (Full Disk Access, EventKit, contacts).
    case permissionDenied(String)                       // e.g. "Full Disk Access", "Calendar"

    /// The connector was cancelled by the running pipeline.
    case cancelled(String)                              // e.g. "Gmail"

    /// The connector's schema has changed and is no longer supported.
    case unsupportedSchema(String, detail: String?)     // e.g. "chat.db", "column ZFOO missing"

    /// The connector is healthy but has no eligible work for this run.
    case empty(String)                                  // e.g. "Apple Calendar"

    /// A rate limit was hit (remote API throttling).
    case rateLimited(String, retryAfter: TimeInterval?)  // e.g. "Gmail", Optional(60)

    var description: String {
        switch self {
        case .fileReadError(let path):
            return "Failed to read file: \(path)"
        case .databaseError(let name, let code):
            return "Database error in \(name) (code \(code))"
        case .networkError(let source, let code):
            return "Network error from \(source)" + (code.map { " (HTTP \($0))" } ?? "")
        case .authExpired(let source):
            return "Auth expired for \(source)"
        case .invalidResponse(let source, let rule):
            return "Invalid response from \(source) (rule: \(rule))"
        case .noReadSurface(let source):
            return "No read surface for \(source)"
        case .storageError(let store):
            return "Storage error in \(store)"
        case .timeout(let source, let seconds):
            return "Timeout on \(source) after \(seconds)s"
        case .parseError(let source, let detail):
            return "Parse error in \(source): \(detail)"
        case .permissionDenied(let perm):
            return "Permission denied: \(perm)"
        case .cancelled(let source):
            return "Cancelled: \(source)"
        case .unsupportedSchema(let source, let detail):
            return "Unsupported schema in \(source)" + (detail.map { " — \($0)" } ?? "")
        case .empty(let source):
            return "No eligible work from \(source)"
        case .rateLimited(let source, let retryAfter):
            return "Rate limited by \(source)" + (retryAfter.map { " (retry after \($0)s)" } ?? "")
        }
    }

    /// A human-friendly message for the processing UI (no paths, tokens, or internal details).
    var userMessage: String {
        switch self {
        case .fileReadError:
            return "Could not read a file. Check that it still exists and is accessible."
        case .databaseError:
            return "A local database could not be accessed. Ensure Full Disk Access is granted."
        case .networkError:
            return "A cloud connection failed. Check your internet and try again."
        case .authExpired:
            return "A cloud connection needs to be re-authenticated."
        case .invalidResponse:
            return "A cloud service returned unexpected data. Try again later."
        case .noReadSurface:
            return "A connected service has no available read tools."
        case .storageError:
            return "The local storage failed to save. Check available disk space."
        case .timeout:
            return "A source took too long to respond. Retrying next run."
        case .parseError:
            return "A local source's data format could not be read."
        case .permissionDenied(let perm):
            return "Permission is needed for \(perm). Check System Settings."
        case .cancelled:
            return "The read was cancelled."
        case .unsupportedSchema:
            return "A local source's format has changed. Updating Sentient OS may fix it."
        case .empty:
            return "No new items to process from this source."
        case .rateLimited:
            return "A cloud service is temporarily busy. Try again later."
        }
    }

    /// The Sentry event type for fingerprinting this error.
    var sentryType: String {
        switch self {
        case .fileReadError: return "file_read"
        case .databaseError: return "database"
        case .networkError: return "network"
        case .authExpired: return "auth_expired"
        case .invalidResponse: return "invalid_response"
        case .noReadSurface: return "no_read_surface"
        case .storageError: return "storage"
        case .timeout: return "timeout"
        case .parseError: return "parse"
        case .permissionDenied: return "permission"
        case .cancelled: return "cancelled"
        case .unsupportedSchema: return "unsupported_schema"
        case .empty: return "empty"
        case .rateLimited: return "rate_limited"
        }
    }
}

// MARK: - RateLimitPolicy (v2 protocol)

/// Per-connector rate-limit policy. Controls how many operations a connector can perform
/// within a sliding time window, with optional backoff on rejection.
///
/// Policies are set per-connector based on the source's nature: local DBs have no limit,
/// cloud APIs have strict per-minute caps, and MCP connectors have per-model-tier budgets.
struct RateLimitPolicy: Sendable {
    /// Maximum operations per sliding window. `nil` means no rate limit.
    let maxOperations: Int?
    /// Sliding window duration. Ignored when `maxOperations` is `nil`.
    let window: TimeInterval
    /// Backoff multiplier on rate-limit response. The next retry waits
    /// `window * multiplier` seconds after receiving a rate-limit error.
    let backoffMultiplier: Double

    /// No rate limit (default for local DB connectors).
    static let none = RateLimitPolicy(maxOperations: nil, window: 0, backoffMultiplier: 1.0)

    /// Conservative limit for slow or strict APIs (Gmail, Outlook).
    static let strict = RateLimitPolicy(maxOperations: 5, window: 60, backoffMultiplier: 2.0)

    /// Moderate limit for standard APIs (Slack, Notion, Granola).
    static let moderate = RateLimitPolicy(maxOperations: 15, window: 60, backoffMultiplier: 1.5)

    /// Aggressive limit for permissive APIs (Google Drive).
    static let aggressive = RateLimitPolicy(maxOperations: 30, window: 60, backoffMultiplier: 1.2)

    init(maxOperations: Int?, window: TimeInterval = 60, backoffMultiplier: Double = 1.5) {
        self.maxOperations = maxOperations
        self.window = window
        self.backoffMultiplier = backoffMultiplier
    }

    /// Whether this policy imposes any actual limit.
    var isUnlimited: Bool { maxOperations == nil }
}

// MARK: - TimeoutPolicy (v2 protocol)

/// Per-connector timeout policy. Controls the wall-clock deadline for a connector's
/// work, replacing the old single 60-minute total cap with per-connector granularity.
///
/// The timeout covers all operations within a single connector's turn (listing + loading).
/// A per-connector timeout prevents a single hung source from blocking the entire pipeline.
struct TimeoutPolicy: Sendable {
    /// Maximum wall-clock seconds for the entire connector turn. `nil` means no timeout.
    let maxSeconds: Double?
    /// Maximum seconds for a single `load()` call. `nil` falls back to `maxSeconds`.
    let loadTimeout: Double?
    /// Maximum seconds for a single `buckets()` call. `nil` falls back to `maxSeconds`.
    let listTimeout: Double?
    /// Whether the connector should be silently skipped on timeout (vs. reported as a failure).
    let silentOnTimeout: Bool
    /// Maximum number of automatic retries on transient failure (network, timeout).
    let maxRetries: Int

    /// No timeout (use for debug or extremely slow sources).
    static let none = TimeoutPolicy(
        maxSeconds: nil, loadTimeout: nil, listTimeout: nil, silentOnTimeout: false, maxRetries: 0
    )

    /// Standard timeout for local file/notes connectors (fast, retry-tolerant).
    static let localStandard = TimeoutPolicy(
        maxSeconds: 30, loadTimeout: 15, listTimeout: 10, silentOnTimeout: false, maxRetries: 2
    )

    /// Timeout for local DB connectors (SQLite read + typedstream decode).
    static let localDB = TimeoutPolicy(
        maxSeconds: 30, loadTimeout: 15, listTimeout: 10, silentOnTimeout: false, maxRetries: 2
    )

    /// Timeout for cloud API connectors (network-dependent, can hang).
    static let cloudStandard = TimeoutPolicy(
        maxSeconds: 60, loadTimeout: 30, listTimeout: 20, silentOnTimeout: false, maxRetries: 3
    )

    /// Timeout for cloud API connectors where silent skip is preferred on timeout.
    static let cloudSilent = TimeoutPolicy(
        maxSeconds: 60, loadTimeout: 30, listTimeout: 20, silentOnTimeout: true, maxRetries: 3
    )

    /// Standard timeout for MCP connectors (variable latency, retry-tolerant).
    static let mcpStandard = TimeoutPolicy(
        maxSeconds: 45, loadTimeout: 20, listTimeout: 15, silentOnTimeout: false, maxRetries: 2
    )

    /// Configurable default policy. Use `TimeoutPolicy.default = .cloudStandard` to change.
    /// Defaults to `.localStandard` so existing connectors are unaffected.
    static var `default`: TimeoutPolicy = .localStandard

    init(maxSeconds: Double?, loadTimeout: Double? = nil, listTimeout: Double? = nil,
         silentOnTimeout: Bool = false, maxRetries: Int = 0) {
        self.maxSeconds = maxSeconds
        self.loadTimeout = loadTimeout ?? maxSeconds
        self.listTimeout = listTimeout ?? maxSeconds
        self.silentOnTimeout = silentOnTimeout
        self.maxRetries = maxRetries
    }

    /// The effective timeout for a single operation, with the configured or default fallback.
    func effective(for operation: Operation) -> Double? {
        switch operation {
        case .buckets: return listTimeout ?? maxSeconds
        case .load: return loadTimeout ?? maxSeconds
        }
    }

    enum Operation: String { case buckets, load }

    var isUnlimited: Bool { maxSeconds == nil }
}

// MARK: - TimeoutPolicy presets

/// Convenience: build a timeout policy from standard presets.
extension TimeoutPolicy {
    /// Build a timeout policy from a preset.
    static func fromPreset(_ preset: Preset) -> TimeoutPolicy {
        switch preset {
        case .localStandard: return .localStandard
        case .localDB: return .localDB
        case .cloudStandard: return .cloudStandard
        case .cloudSilent: return .cloudSilent
        case .mcpStandard: return .mcpStandard
        }
    }

    /// Presets for common connector types.
    enum Preset: Sendable {
        case localStandard
        case localDB
        case cloudStandard
        case cloudSilent
        case mcpStandard
    }
}

// MARK: - Connector protocol (v2)

protocol Connector: Sendable {
    var kind: SourceKind { get }
    /// Engine KV-cache size for this connector's items (chats feed big windows → `ChatWindowing.kvCacheTokens`; default 4096).
    var maxTokens: Int { get }

    /// Rate-limit policy for this connector (v2). Overrides any global default.
    var rateLimitPolicy: RateLimitPolicy { get }

    /// Timeout policy for this connector (v2). Overrides any global default.
    var timeoutPolicy: TimeoutPolicy { get }

    /// Current eligible work-items per bucket, newest-first. `marks` = the current per-bucket pointer
    /// (a query HINT only — a connector MAY use it to read efficiently, e.g. chats' `WHERE rowid >
    /// mark`; IterativeRun still filters/advances authoritatively, so returning extra items is
    /// harmless). For an initial run the run passes `[:]` ⇒ return everything (still connector-capped).
    func buckets(since marks: [String: ItemKey]) throws -> [Bucket]

    /// Expensive content for one item → Artifact for Triage.
    func load(_ item: Candidate) throws -> Artifact
}

extension Connector {
    /// Execute an async operation with timeout enforcement.
    /// Returns `.timeout` error if the deadline is exceeded.
    ///
    /// - Parameters:
    ///   - policy: The timeout policy to apply.
    ///   - operation: The async operation to execute.
    /// - Returns: The operation's return value.
    /// - Throws: The operation's error, or `ConnectorError.timeout` if the deadline is exceeded.
    func executeWithTimeout<T>(
        _ policy: TimeoutPolicy,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        let maxSeconds = policy.maxSeconds
        guard let deadline = maxSeconds else {
            // No timeout configured — execute directly.
            return try await operation()
        }
        
        let operationTask = Task {
            try Task.checkCancellation()
            return try await operation()
        }
        
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(deadline))
            throw ConnectorError.timeout(String(describing: Self.self), seconds: deadline)
        }
        
        // Race: the first to finish wins; the loser is cancelled.
        let winner = await {
            if operationTask.isCancelled {
                // Timeout won — cancel the operation and return its error.
                return (.failure(ConnectorError.timeout(
                    String(describing: Self.self), seconds: deadline
                )))
            } else {
                // Operation won — cancel the timeout and unwrap.
                timeoutTask.cancel()
                return (.success(await operationTask.value))
            }
        }()
        
        switch winner {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
    
    /// Execute an async operation with this connector's configured timeout policy.
    /// Convenience wrapper that uses `self.timeoutPolicy`.
    func executeWithTimeout<T>(
        operation: @escaping () async throws -> T
    ) async throws -> T {
        return try await executeWithTimeout(timeoutPolicy, operation: operation)
    }
    
    var maxTokens: Int { 4096 }
    var rateLimitPolicy: RateLimitPolicy { .none }
    var timeoutPolicy: TimeoutPolicy { .localStandard }
    /// Default severity maps to the connector's risk classification.
    /// Override in specific connectors for custom severity.
    var severity: ConnectorSeverity { .fromRisk(self.risk) }
}

// MARK: - ConnectorSeverity

/// Severity level for connector operations (parallel to ConnectorRisk but separate
/// to allow independent tuning of scheduling vs error-handling priorities).
enum ConnectorSeverity: Int, Comparable, Sendable {
    /// Low-severity errors: transient, user-visible but non-blocking.
    case low = 0
    /// Medium-severity errors: may block downstream work temporarily.
    case medium = 1
    /// High-severity errors: blocking, require user attention.
    case high = 2

    static func < (lhs: ConnectorSeverity, rhs: ConnectorSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Convert from ConnectorRisk — the default mapping.
    static func fromRisk(_ risk: ConnectorRisk) -> ConnectorSeverity {
        switch risk {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }
}

extension Connector {
    /// Default severity maps to the connector's risk classification.
    /// Override in specific connectors for custom severity.
    var severity: ConnectorSeverity { .fromRisk(self.risk) }
}

// MARK: - ConnectorRisk (for batch scheduling)

/// Risk level for connector batch scheduling. Low-risk connectors execute first (local, fast),
/// high-risk with backoff (cloud, network-dependent).
enum ConnectorRisk: Sendable, Comparable {
    /// Local, fast, unlikely to hang (files, local notes).
    case low
    /// Local DB with WAL copy (WhatsApp, iMessage, Mail).
    case medium
    /// Network-dependent, may timeout or fail (cloud, MCP).
    case high

    static func < (lhs: ConnectorRisk, rhs: ConnectorRisk) -> Bool {
        switch (lhs, rhs) {
        case (.low, .low): return false
        case (.low, .medium), (.low, .high): return true
        case (.medium, .medium), (.medium, .high): return false
        case (.medium, .low), (.high, _): return false
        case (.high, .high): return false
        }
    }
}

extension Connector {
    /// Default risk classification based on connector kind (v2).
    /// Override in specific connectors for custom classification.
    var risk: ConnectorRisk {
        switch kind {
        case .file, .notes:
            return .low
        case .whatsapp, .imessage, .appleMail, .siyuan:
            return .medium
        case .gmail, .calendar, .appleCalendar, .mcp:
            return .high
        }
    }
}
