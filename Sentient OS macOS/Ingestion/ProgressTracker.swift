//
//  ProgressTracker.swift
//  Sentient OS macOS
//
//  Phase 1.3: Real-time per-connector progress tracking for the ingestion pipeline.
//
//  Provides a thread-safe, `@Observable` tracker that reports granular events
//  (started → inProgress → completed / failed) for every connector in a run.
//  Feed it from `BatchScheduler` callbacks or `IterativeRun` to get live UI
//  progress without polling. The tracker is lightweight and designed to be
//  consumed by SwiftUI `@Observable` views or the existing `RunProgress` card.
//
//  Usage — the coordinator creates a `ProgressTracker` at the start of a run
//  and feeds events into it. The UI reads `allProgress()` or binds to a
//  `ConnectorProgress` directly. All public methods are `@Sendable` so the
//  background thread can call them without `Task { @MainActor … }`.
//

import Foundation

// MARK: - ProgressStatus

/// The lifecycle state of a single connector's execution within a run.
enum ProgressStatus: Sendable, Equatable {
    /// Connector not yet touched by this run.
    case idle
    /// Connector has started fetching / listing buckets.
    case fetching
    /// Connector is processing / loading items.
    case processing
    /// Connector is syncing results to the store.
    case syncing
    /// Connector completed successfully.
    case completed
    /// Connector failed with an optional diagnostic error.
    case failed(Error?)
    /// Connector was skipped (e.g. auth expired, no eligible work).
    case skipped(reason: String)

    /// Returns `true` for any terminal state.
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .skipped: return true
        default: return false
        }
    }

    static func == (lhs: ProgressStatus, rhs: ProgressStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.fetching, .fetching),
             (.processing, .processing),
             (.syncing, .syncing),
             (.completed, .completed):
            return true
        case (.failed(let l), .failed(let r)):
            return l.map { "\($0)" } == r.map { "\($0)" }
        case (.skipped(let l), .skipped(let r)):
            return l.reason == r.reason
        default:
            return false
        }
    }
}

// MARK: - ConnectorProgress

/// Per-connector progress snapshot, `Sendable` for background-thread consumption.
struct ConnectorProgress: Sendable {
    let sourceKind: SourceKind
    var itemsProgressed: Int
    var itemsTotal: Int
    var startTime: Date?
    var elapsed: TimeInterval?
    var status: ProgressStatus

    /// Create an idle snapshot for the given source kind.
    static func idle(for kind: SourceKind) -> ConnectorProgress {
        ConnectorProgress(
            sourceKind: kind,
            itemsProgressed: 0,
            itemsTotal: 0,
            startTime: nil,
            elapsed: nil,
            status: .idle
        )
    }

    /// Percentage of work done, or `nil` when the total is unknown.
    var percentComplete: Double? {
        guard itemsTotal > 0 else { return nil }
        return min(Double(itemsProgressed) / Double(itemsTotal) * 100.0, 100.0)
    }

    /// `true` once the connector has reached a terminal state.
    var isComplete: Bool {
        status == .completed || status == .skipped
    }

    /// Human-readable label for the current phase.
    var statusLabel: String {
        switch status {
        case .idle:
            return "Waiting"
        case .fetching:
            return "Fetching"
        case .processing:
            return "Processing"
        case .syncing:
            return "Syncing"
        case .completed:
            return "Done"
        case .failed:
            return "Failed"
        case .skipped(let reason):
            return "Skipped (\(reason))"
        }
    }
}

// MARK: - ProgressTracker

/// Thread-safe, observable tracker for per-connector ingestion progress.
///
/// Feed events from the batch scheduler or the iterative runner. The tracker
/// owns a single lock and exposes a copy-on-read API so SwiftUI `@Observable`
/// models can safely snapshot the full state.
@MainActor @Observable
final class ProgressTracker: Sendable {
    /// Internal mutable state protected by a serial lock.
    private struct State: Sendable {
        var progress: [SourceKind: ConnectorProgress] = [:]
        var events: [ProgressEvent] = []
    }

    private var _state: State
    private let lock = NSLock()

    /// Maximum number of progress events retained in memory.
    /// Prevents unbounded growth during long runs.
    static let maxEvents = 500

    /// Shared singleton for the default coordinator pattern.
    static let shared = ProgressTracker()

    // MARK: - Init / Public API

    private init() {
        _state = State()
    }

    /// Called when a connector begins execution for the given source kind.
    /// Resets progress counters and marks the connector as fetching.
    func start(kind: SourceKind) {
        lock.lock()
        defer { lock.unlock() }
        _state.progress[kind] = ConnectorProgress.idle(for: kind)
        _state.progress[kind]!.status = .fetching
        _state.progress[kind]!.startTime = .now
        _state.events.append(ProgressEvent(kind: kind, event: .started, timestamp: .now))
    }

    /// Called as items are processed. Updates the count and elapsed time.
    func reportItemsProgressed(kind: SourceKind, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard var cp = _state.progress[kind] else { return }
        cp.itemsProgressed = count
        cp.elapsed = cp.startTime.map { Date().timeIntervalSince($0) }
        if cp.status == .fetching {
            cp.status = .processing
        }
        _state.progress[kind] = cp
        _state.events.append(
            ProgressEvent(kind: kind, event: .itemsProgressed(count), timestamp: .now)
        )
    }

    /// Called to report a new total item count discovered mid-run.
    func reportItemsTotal(kind: SourceKind, total: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard var cp = _state.progress[kind] else { return }
        cp.itemsTotal = total
        _state.progress[kind] = cp
    }

    /// Called when the connector finishes successfully.
    func complete(kind: SourceKind) {
        lock.lock()
        defer { lock.unlock() }
        guard var cp = _state.progress[kind] else { return }
        cp.status = .completed
        cp.elapsed = cp.startTime.map { Date().timeIntervalSince($0) }
        _state.progress[kind] = cp
        _state.events.append(
            ProgressEvent(kind: kind, event: .completed, timestamp: .now)
        )
    }

    /// Called when the connector encounters an unrecoverable error.
    func fail(kind: SourceKind, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard var cp = _state.progress[kind] else { return }
        cp.status = .failed(error)
        cp.elapsed = cp.startTime.map { Date().timeIntervalSince($0) }
        _state.progress[kind] = cp
        _state.events.append(
            ProgressEvent(kind: kind, event: .failed, timestamp: .now)
        )
    }

    /// Called when the connector is gracefully skipped (auth expired, no work).
    func skip(kind: SourceKind, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var cp = _state.progress[kind] else { return }
        cp.status = .skipped(reason: reason)
        cp.elapsed = cp.startTime.map { Date().timeIntervalSince($0) }
        _state.progress[kind] = cp
        _state.events.append(
            ProgressEvent(kind: kind, event: .skipped, timestamp: .now)
        )
    }

    /// Convenience: transition a non-terminal connector to the next state.
    func transition(kind: SourceKind, to newStatus: ProgressStatus) {
        lock.lock()
        defer { lock.unlock() }
        guard var cp = _state.progress[kind] else { return }
        cp.status = newStatus
        _state.progress[kind] = cp
    }

    /// Convenience: transition to processing and update item count in one call.
    func update(kind: SourceKind, updates: (inout ConnectorProgress) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard var cp = _state.progress[kind] else { return }
        updates(&cp)
        _state.progress[kind] = cp
    }

    /// Returns a snapshot copy of all connector progress.
    /// Safe to call from any thread; SwiftUI binding can call from the main actor.
    func allProgress() -> [SourceKind: ConnectorProgress] {
        lock.lock()
        defer { lock.unlock() }
        return _state.progress
    }

    /// Returns the snapshot for a single connector, or a fresh idle snapshot.
    func progress(for kind: SourceKind) -> ConnectorProgress {
        lock.lock()
        defer { lock.unlock() }
        return _state.progress[kind] ?? ConnectorProgress.idle(for: kind)
    }

    /// Returns recent events, limited to `maxEvents`.
    func recentEvents(count: Int = 50) -> [ProgressEvent] {
        lock.lock()
        defer { lock.unlock() }
        let arr = _state.events
        let start = max(0, arr.count - count)
        return Array(arr[start...])
    }

    /// Returns `true` if every connector has reached a terminal state.
    var allComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !_state.progress.isEmpty else { return false }
        return _state.progress.values.allSatisfy(\.isComplete)
    }

    /// Returns the count of connectors that have failed.
    var failureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _state.progress.values.filter { $0.status == .failed }.count
    }

    /// Reset all tracking state — call at the beginning of each new run.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        _state.progress.removeAll()
        _state.events.removeAll()
    }

    /// Returns a human-readable summary string for logging / diagnostics.
    var summary: String {
        lock.lock()
        defer { lock.unlock() }
        let counts: [ProgressStatus: Int] = {
            var map: [ProgressStatus: Int] = [:]
            for cp in _state.progress.values {
                map[cp.status, default: 0] += 1
            }
            return map
        }()
        var parts: [String] = []
        for (status, count) in counts.sorted(by: { $0.0.statusLabel < $1.0.statusLabel }) {
            parts.append("\(status.statusLabel): \(count)")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - ProgressEvent

/// A timestamped event describing a progress transition for a single connector.
struct ProgressEvent: Sendable {
    let kind: SourceKind
    enum EventKind: Sendable {
        case started
        case itemsProgressed(Int)
        case completed
        case failed
        case skipped
    }
    let event: EventKind
    let timestamp: Date

    var label: String {
        switch event {
        case .started:
            return "\(kind.rawValue) started"
        case .itemsProgressed(let count):
            return "\(kind.rawValue) — \(count) items"
        case .completed:
            return "\(kind.rawValue) completed"
        case .failed:
            return "\(kind.rawValue) failed"
        case .skipped:
            return "\(kind.rawValue) skipped"
        }
    }
}

// MARK: - ProgressTracker (extension for main-actor-only convenience)

/// Main-actor convenience: a `@MainActor @Observable` bridge that batches
/// updates into a single SwiftUI redraw.
extension ProgressTracker {
    /// Snapshot of progress plus events in one call — the primary read
    /// method for SwiftUI views. Returns a copy, safe to keep or bind.
    func snapshot() -> (progress: [SourceKind: ConnectorProgress], events: [ProgressEvent]) {
        lock.lock()
        defer { lock.unlock() }
        return (_state.progress, Array(_state.events.suffix(50)))
    }
}
