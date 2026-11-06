//
//  BatchScheduler.swift
//  Sentient OS macOS
//
//  Phase 1.2: Smart-parallel connector execution by risk level.
//
//  Groups connectors by `ConnectorRisk` and executes low-risk in parallel first (local sources),
//  then medium, then high-risk with backoff between batches. This ensures fast, reliable sources
//  complete before network-dependent ones start — reducing total pipeline time and avoiding
//  contention on shared resources (GPU, disk I/O for WAL copies).
//
//  The scheduler replaces the old linear connector loop in IterativeRun with a structured
//  parallel pipeline. Low-risk connectors can share a single model load; medium-risk get
//  isolated model contexts; high-risk use their own timeouts and backoff.
//

import Foundation

// MARK: - BatchScheduler (struct-based, functional)

/// Smart-parallel connector batch scheduler (v2). Groups connectors by risk and executes
/// sequentially across risk tiers, but in parallel within each tier. Low-risk (local, fast)
/// runs first; high-risk (network-dependent) get backoff protection.
struct BatchScheduler {
    /// The configured batch size for each risk tier. Controls how many connectors run in parallel.
    struct BatchConfig: Sendable {
        let lowRiskParallelism: Int     // low-risk: parallelism budget
        let mediumRiskParallelism: Int  // medium-risk: limited parallelism
        let highRiskParallelism: Int    // high-risk: serialized or 1
        let interBatchBackoff: TimeInterval  // seconds to wait between risk tiers

        static let standard = BatchConfig(
            lowRiskParallelism: 8,
            mediumRiskParallelism: 4,
            highRiskParallelism: 1,
            interBatchBackoff: 1.0
        )

        static let aggressive = BatchConfig(
            lowRiskParallelism: 16,
            mediumRiskParallelism: 8,
            highRiskParallelism: 2,
            interBatchBackoff: 0.5
        )

        static let conservative = BatchConfig(
            lowRiskParallelism: 4,
            mediumRiskParallelism: 2,
            highRiskParallelism: 1,
            interBatchBackoff: 2.0
        )

        init(lowRiskParallelism: Int = 8, mediumRiskParallelism: Int = 4,
             highRiskParallelism: Int = 1, interBatchBackoff: TimeInterval = 1.0) {
            self.lowRiskParallelism = lowRiskParallelism
            self.mediumRiskParallelism = mediumRiskParallelism
            self.highRiskParallelism = highRiskParallelism
            self.interBatchBackoff = interBatchBackoff
        }
    }

    /// Result of executing a single connector through one bucket.
    struct ConnectorResult: Sendable {
        let kind: SourceKind
        let buckets: [Bucket]
        let executionTime: TimeInterval
        let error: Error?
        let itemsCount: Int

        var succeeded: Bool { error == nil }
    }

    /// Groups all connectors by risk level and returns them in execution order
    /// (low → medium → high).
    static func groupByRisk(connectors: [any Connector]) -> [ConnectorRisk: [any Connector]] {
        var groups: [ConnectorRisk: [any Connector]] = [:]
        for connector in connectors {
            let risk = connector.risk
            groups[risk, default: []].append(connector)
        }
        // Return in sorted order: low, medium, high
        return groups
    }

    /// Execute all connectors in risk-ordered batches. Low-risk first (parallel),
    /// then medium (limited parallel), then high (serialized with backoff).
    ///
    /// - Parameters:
    ///   - connectors: All connectors to execute.
    ///   - mode: The run mode (initial, iterative, auto).
    ///   - store: The CycleStore for progress tracking.
    ///   - engineFactory: Creates or returns a model engine per connector.
    ///   - onProgress: Progress callback for each connector's work.
    /// - Returns: Per-connector results with timing and error info.
    static func execute<T>(
        connectors: [any Connector],
        mode: IterativeRun.Mode,
        store: CycleStore,
        engineFactory: @escaping @Sendable (any Connector) async throws -> T,
        onProgress: @Sendable @escaping (ProgressUpdate) -> Void = { _ in }
    ) async -> [ConnectorResult] {
        guard !connectors.isEmpty else { return [] }

        let config = BatchConfig.standard
        let groups = groupByRisk(connectors: connectors)
        var results: [ConnectorResult] = []

        // Execute each risk tier sequentially, but connectors within a tier in parallel.
        let orderedRisks: [ConnectorRisk] = [.low, .medium, .high]
        for risk in orderedRisks {
            guard let group = groups[risk], !group.isEmpty else { continue }

            let batchStart = Date()
            let batchResults = await executeBatch(
                connectors: group,
                mode: mode,
                store: store,
                engineFactory: engineFactory,
                maxParallel: maxRiskParallelism(risk, config: config),
                onProgress: onProgress
            )
            results += batchResults

            let batchTime = Date().timeIntervalSince(batchStart)
            onProgress(.batchCompleted(
                risk: risk,
                connectors: group.count,
                time: batchTime
            ))

            // Inter-batch backoff between risk tiers (except after the last one).
            if risk != .high, let nextRisk = nextRisk(risk) {
                if groups[nextRisk] != nil {
                    await Task.sleep(for: .seconds(config.interBatchBackoff))
                }
            }
        }

        return results
    }

    /// Execute a single batch of connectors at the specified parallelism level.
    /// Each connector runs independently; errors in one don't cancel others.
    private static func executeBatch<T>(
        connectors: [any Connector],
        mode: IterativeRun.Mode,
        store: CycleStore,
        engineFactory: @escaping @Sendable (any Connector) async throws -> T,
        maxParallel: Int,
        onProgress: @Sendable @escaping (ProgressUpdate) -> Void
    ) async -> [ConnectorResult] {
        guard maxParallel > 0 else { return [] }

        var results: [any Connector: ConnectorResult?] = [:]
        var remaining = connectors

        while !remaining.isEmpty {
            let batchSize = min(maxParallel, remaining.count)
            let batch = Array(remaining.prefix(batchSize))
            remaining = Array(remaining.dropFirst(batchSize))

            // Run batch in parallel using a task group.
            let batchResults = await withThrowingTaskGroup(of: (any Connector, ConnectorResult?).self) { group in
                for connector in batch {
                    group.addTask {
                        let start = Date()
                        do {
                            let engine = try await engineFactory(connector)
                            let buckets = try connector.buckets(since: [:])
                            let elapsed = Date().timeIntervalSince(start)
                            return (connector, ConnectorResult(
                                kind: connector.kind,
                                buckets: buckets,
                                executionTime: elapsed,
                                error: nil,
                                itemsCount: buckets.reduce(0) { $0 + $1.items.count }
                            ))
                        } catch {
                            let elapsed = Date().timeIntervalSince(start)
                            return (connector, ConnectorResult(
                                kind: connector.kind,
                                buckets: [],
                                executionTime: elapsed,
                                error: error,
                                itemsCount: 0
                            ))
                        }
                    }
                }

                var localResults: [(any Connector, ConnectorResult?)] = []
                for try await result in group {
                    localResults.append(result)
                    onProgress(.connectorCompleted(
                        kind: result.0.kind,
                        items: result.1?.itemsCount ?? 0,
                        error: result.1?.error,
                        time: result.1?.executionTime ?? 0
                    ))
                }
                return localResults
            }

            for (connector, result) in batchResults {
                results[connector] = result
            }
        }

        return connectors.compactMap { results[$0] }
    }

    private static func maxRiskParallelism(_ risk: ConnectorRisk, config: BatchConfig) -> Int {
        switch risk {
        case .low: return config.lowRiskParallelism
        case .medium: return config.mediumRiskParallelism
        case .high: return config.highRiskParallelism
        }
    }

    private static func nextRisk(_ risk: ConnectorRisk) -> ConnectorRisk? {
        switch risk {
        case .low: return .medium
        case .medium: return .high
        case .high: return nil
        }
    }
}

// MARK: - ProgressUpdate

/// Progress updates from the batch scheduler.
enum ProgressUpdate: Sendable {
    /// A single connector finished its buckets call.
    case connectorCompleted(kind: SourceKind, items: Int, error: Error?, time: TimeInterval)
    /// A risk batch completed all its connectors.
    case batchCompleted(risk: ConnectorRisk, connectors: Int, time: TimeInterval)
}

// MARK: - BatchSchedulerPerConnectorTimeout

/// Per-connector timeout enforcement via BatchScheduler. Wraps each connector's
/// execution in the configured TimeoutPolicy deadline.
struct BatchSchedulerPerConnectorTimeout: Sendable {
    let policy: TimeoutPolicy

    /// Applies the connector's timeout policy to a blocking call.
    /// Returns `.timeout` error if the deadline is exceeded.
    func apply<T>(_ work: @escaping () throws -> T, label: String) throws -> T {
        guard let maxSeconds = policy.maxSeconds else { return try work() }
        let deadline = Date().addingTimeInterval(maxSeconds)

        var result: Result<T, Error>?
        let lock = NSLock()
        let cond = NSCondition()

        DispatchQueue.global(qos: .utility).async {
            lock.lock()
            defer { lock.unlock(); cond.signal() }
            do {
                let value = try work()
                result = .success(value)
            } catch {
                result = .failure(error)
            }
        }

        let waitDeadline = deadline.timeIntervalSinceNow
        guard waitDeadline > 0 else {
            return try work()  // already past deadline
        }

        let start = DispatchTime.now()
        let deadlineTime = DispatchTime.now() + DispatchTimeInterval.seconds(Int(maxSeconds))

        cond.wait(until: deadlineTime)
        lock.lock()
        defer { lock.unlock() }

        if let result = result {
            switch result {
            case .success(let value): return value
            case .failure(let error): throw error
            }
        }

        // Timeout: no result arrived in time.
        throw ConnectorError.timeout(label, seconds: maxSeconds)
    }
}

// MARK: - BatchScheduler (Observable class)

/// Main-actor batch scheduler suitable for UI-bound coordination.
/// Groups connectors by severity, executes sequentially by risk tier,
/// reports per-connector progress, and never lets a single failure
/// cancel the rest of the batch.
@MainActor @Observable
final class BatchScheduler {
    /// A single connector's execution outcome.
    struct BatchResult: Sendable {
        let connectorName: String
        let success: Bool
        let error: String?
        let duration: TimeInterval
    }

    static let shared = BatchScheduler()

    private init() {}

    /// Run all connectors in risk-ordered batches.
    /// - Parameters:
    ///   - connectors: Connectors to execute.
    ///   - onProgress: Called for each connector's result.
    /// - Returns: A `BatchResult` per connector.
    func runBatches(
        connectors: [any Connector],
        onProgress: @escaping (String, BatchResult) -> Void = { _, _ in }
    ) async -> [BatchResult] {
        guard !connectors.isEmpty else { return [] }

        // Group by severity (low → medium → high).
        let groups = groupByRisk(connectors: connectors)
        let orderedRisks: [ConnectorRisk] = [.low, .medium, .high]

        var allResults: [BatchResult] = []

        for risk in orderedRisks {
            guard let group = groups[risk], !group.isEmpty else { continue }

            // Execute this tier in parallel.
            let tierResults = await runTier(connectors: group)

            // Report each result via callback.
            for result in tierResults {
                onProgress(result.connectorName, result)
            }
            allResults.append(contentsOf: tierResults)
        }

        return allResults
    }

    /// Execute a single risk tier of connectors in parallel.
    private func runTier(connectors: [any Connector]) async -> [BatchResult] {
        var results: [BatchResult] = []
        let taskResults = await withTaskGroup(of: BatchResult.self) { group in
            for connector in connectors {
                group.addTask { [connector] in
                    let name = String(describing: type(of: connector))
                    let start = Date()
                    do {
                        _ = try connector.buckets(since: [:])
                        let duration = Date().timeIntervalSince(start)
                        return BatchResult(
                            connectorName: name,
                            success: true,
                            error: nil,
                            duration: duration
                        )
                    } catch {
                        let duration = Date().timeIntervalSince(start)
                        return BatchResult(
                            connectorName: name,
                            success: false,
                            error: error.localizedDescription,
                            duration: duration
                        )
                    }
                }
            }

            var tierResults: [BatchResult] = []
            for await result in group {
                tierResults.append(result)
            }
            return tierResults
        }
        return taskResults
    }

    /// Groups all connectors by risk level (convenience alias for static helper).
    static func groupByRisk(connectors: [any Connector]) -> [ConnectorRisk: [any Connector]] {
        var groups: [ConnectorRisk: [any Connector]] = [:]
        for connector in connectors {
            let risk = connector.risk
            groups[risk, default: []].append(connector)
        }
        return groups
    }
}
