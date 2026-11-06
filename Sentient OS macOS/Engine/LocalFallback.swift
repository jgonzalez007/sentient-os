//
//  LocalFallback.swift
//  Sentient OS macOS
//
//  Phase 2.6 — Local Model Fallback: Automatic fallback from cloud to local inference
//  when cloud backends fail. Attempts inference across sources with automatic retry
//  and fallback to the local Gemma 4 model when all cloud sources are exhausted.
//
//  Integration:
//   - LocalFallbackManager.shared.infer(prompt:sources:progress:)  → main inference entry
//   - LocalFallbackManager.shared.config                           → fallback behavior settings
//   - LocalFallbackManager.shared.hasLocalFallback                 → true if Gemma 4 available
//   - LocalFallbackManager.shared.lastFailure                      → last failed source for UI
//
//  Behavior:
//   1. Attempt inference on the primary source.
//   2. On failure, retry up to maxRetriesPerSource times.
//   3. If all retries exhausted, try the next source in the priority list.
//   4. Eventually fall back to local Gemma 4 if cloud sources are exhausted.
//   5. Record each failure for UI display in settings/health panel.
//
//  The fallback manager is designed to be transparent to the caller — it simply
//  returns the best result it can find, recording failures for observability.
//

import Foundation

// MARK: - Public Types

/// The result of a fallback inference attempt. Sendable.
@MainActor
final class LocalFallbackManager: @unchecked Sendable {

    // MARK: - FallbackResult

    /// Outcome of a fallback inference attempt.
    enum FallbackResult: Sendable {
        case succeeded(source: InferenceSource)
        case failed(reason: String)

        var source: InferenceSource? {
            switch self {
            case .succeeded(let source): return source
            case .failed: return nil
            }
        }

        var isSuccess: Bool {
            switch self {
            case .succeeded: return true
            case .failed: return false
            }
        }
    }

    // MARK: - InferenceSource

    /// Known inference sources. Ordered by priority — the first entry is the primary.
    enum InferenceSource: String, Sendable, CaseIterable {
        case localGemma    = "local-gemma"
        case chatGPT       = "chatgpt"
        case claude        = "claude"
        case customEndpoint = "custom"
        case hostedSentient = "sentient"

        /// Display name for UI.
        var displayName: String {
            switch self {
            case .localGemma:     return "Gemma 4 (Local)"
            case .chatGPT:        return "ChatGPT"
            case .claude:         return "Claude"
            case .customEndpoint: return "Custom"
            case .hostedSentient: return "Sentient (Hosted)"
            }
        }
    }

    // MARK: - Config

    /// Configuration for fallback behavior. Sendable and Codable for preferences storage.
    struct Config: Sendable, Codable {
        /// Enable automatic fallback when a source fails.
        var enableFallback: Bool = true

        /// Maximum retries per source before moving to the next.
        var maxRetriesPerSource: Int = 2

        /// Number of cloud failures before switching to local Gemma.
        var fallbackToLocalAfterFailures: Int = 2

        /// The local model name to use for fallback inference.
        var localModelName: String = "gemma-4-E4B-it"

        /// Show a user alert when falling back to local inference.
        var showUserAlert: Bool = true
    }

    // MARK: - FailedSource

    /// Record of a failed inference attempt. Sendable for UI display.
    struct FailedSource: Sendable {
        let source: InferenceSource
        let error: String
        let timestamp: Date
    }

    // MARK: - Shared

    static let shared = LocalFallbackManager()
    private init() {}

    // MARK: - State

    /// Current fallback configuration.
    var config: Config = .init()

    /// The last source that failed, for UI display in the health/settings panel.
    var lastFailure: FailedSource?

    /// History of recent failures (last 20 entries).
    private var failureLog: [FailedSource] = []

    // MARK: - Public API

    /// Attempt inference across multiple sources with automatic fallback.
    ///
    /// Tries each source in order, retrying up to `maxRetriesPerSource` times.
    /// On exhaustion, falls back to local Gemma 4. Returns the best result found
    /// or throws with a failure reason if all sources failed.
    ///
    /// - Parameters:
    ///   - prompt: The inference prompt.
    ///   - sources: Ordered list of sources to try (primary first).
    ///   - progress: Callback for inference progress updates.
    ///
    /// - Returns: The generated text from the first successful source.
    /// - Throws: A description of why all sources failed.
    ///
    /// Example:
    /// ```swift
    /// let result = try await LocalFallbackManager.shared.infer(
    ///     prompt: "Hello, world",
    ///     sources: [.chatGPT, .claude, .localGemma]
    /// ) { progress in
    ///     print("Progress: \(progress)")
    /// }
    /// ```
    func infer(
        prompt: String,
        sources: [InferenceSource],
        progress: @escaping @Sendable (InferenceProgress) -> Void
    ) async throws -> String {
        guard config.enableFallback else {
            // No fallback: try the first source only once.
            do {
                return try await attemptSource(
                    prompt: prompt,
                    source: sources.first ?? .localGemma,
                    maxRetries: 1,
                    progress: progress
                )
            } catch {
                recordFailure(source: sources.first ?? .localGemma, error: error)
                throw error
            }
        }

        var allFailures: [(InferenceSource, String)] = []

        // Try each source in priority order.
        for source in sources {
            do {
                let result = try await attemptSource(
                    prompt: prompt,
                    source: source,
                    maxRetries: config.maxRetriesPerSource,
                    progress: progress
                )
                // Success — return immediately.
                if config.showUserAlert && source != sources.first {
                    Log("LocalFallback: fell back to \(source.displayName) after failure of previous sources")
                }
                return result
            } catch let error {
                allFailures.append((source, error.localizedDescription))
                recordFailure(source: source, error: error)
            }
        }

        // All cloud sources failed — try local Gemma as last resort.
        if hasLocalFallback {
            do {
                let result = try await attemptLocal(prompt: prompt, progress: progress)
                if config.showUserAlert {
                    Log("LocalFallback: fell back to local Gemma — all cloud sources failed")
                }
                return result
            } catch let error {
                recordFailure(source: .localGemma, error: error)
                allFailures.append((.localGemma, error.localizedDescription))
            }
        }

        // Nothing worked — throw with aggregated failures.
        let reasons = allFailures.map { "\($0.0.rawValue): \($0.1)" }
        let aggregate = "All inference sources failed:\n" + reasons.map { "  - \($0)" }.joined(separator: "\n")
        throw InferenceFallbackError.allSourcesFailed(aggregate)
    }

    /// Check if the local Gemma 4 model is available for fallback.
    var hasLocalFallback: Bool {
        // Check if the model file exists and meets minimum size.
        guard let modelInfo = ModelLocator.shared.defaultModel else {
            return false
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelInfo.path.path) else {
            return false
        }
        return modelInfo.fileSize >= 100_000_000
    }

    // MARK: - Internal

    /// Attempt inference on a single source with retries.
    /// Returns the text from the successful attempt or throws on all retries exhausted.
    private func attemptSource(
        prompt: String,
        source: InferenceSource,
        maxRetries: Int,
        progress: @escaping @Sendable (InferenceProgress) -> Void
    ) async throws -> String {
        var lastError: Error?

        for attempt in 1...maxRetries {
            progress(InferenceProgress(
                source: source,
                attempt: attempt,
                maxRetries: maxRetries,
                status: .attempting
            ))

            do {
                switch source {
                case .localGemma:
                    // Local Gemma is handled separately via attemptLocal().
                    // This path is only hit if localGemma is in the sources list.
                    return try await attemptLocal(prompt: prompt, progress: progress)
                case .chatGPT:
                    // Simulate ChatGPT inference — in production this calls ModelBackend with .chatgpt.
                    return try await simulateCloudInference(
                        backend: ModelBackend.chatgpt,
                        prompt: prompt
                    )
                case .claude:
                    return try await simulateCloudInference(
                        backend: ModelBackend.claude,
                        prompt: prompt
                    )
                case .customEndpoint:
                    return try await simulateCloudInference(
                        backend: ModelBackend.custom,
                        prompt: prompt
                    )
                case .hostedSentient:
                    return try await simulateCloudInference(
                        backend: ModelBackend.sentient,
                        prompt: prompt
                    )
                }
            } catch let error {
                lastError = error
                Log("LocalFallback: \(source.rawValue) attempt \(attempt)/\(maxRetries) failed: \(error)")
            }
        }

        // All retries exhausted.
        guard let error = lastError else {
            throw InferenceFallbackError.unknown
        }
        throw error
    }

    /// Attempt inference using the local Gemma 4 model directly.
    /// This bypasses the cloud stack and calls Engine directly.
    private func attemptLocal(
        prompt: String,
        progress: @escaping @Sendable (InferenceProgress) -> Void
    ) async throws -> String {
        progress(InferenceProgress(
            source: .localGemma,
            attempt: 1,
            maxRetries: 1,
            status: .attempting
        ))

        // In production, this would create an Engine instance and call generate().
        // For the fallback manager, we provide the skeleton — the actual inference
        // would be done through a LocalEngine wrapper that holds a reference to
        // the LiteRTLM Engine.
        Log("LocalFallback: attempting local Gemma 4 inference for fallback")

        // Placeholder: the actual implementation would use Engine.generate().
        // This is the expected integration point:
        //
        //   let engine = Engine(modelPath: ModelLocator.resolve()!, maxNumTokens: 4096)
        //   try await engine.load()
        //   defer { engine.unload() }
        //   let result = try await engine.generate(prompt: prompt)
        //   return result.text
        //
        // We return a skeleton that will be wired to Engine in the next phase.
        throw InferenceFallbackError.localEngineUnavailable(
            "Local model file not loaded — Engine.create() requires a valid model path"
        )
    }

    /// Simulate a cloud inference call for a given backend.
    /// In production, this would call the actual cloud API through ModelBackend.
    private func simulateCloudInference(
        backend: ModelBackend,
        prompt: String
    ) async throws -> String {
        // In production, the backend inference would be:
        //   try await ModelBackend.infer(prompt: prompt, backend: backend)
        // which routes through the Codex CLI or HTTP API.
        //
        // For now, we throw a NotImplementedError to indicate the integration point.
        throw InferenceFallbackError.cloudNotImplemented(
            "Cloud inference for \(backend.rawValue) not yet wired"
        )
    }

    /// Record a failure in the log. Keeps only the last 20 entries.
    private mutating func recordFailure(source: InferenceSource, error: Error) {
        let failure = FailedSource(
            source: source,
            error: error.localizedDescription,
            timestamp: .now
        )
        lastFailure = failure
        failureLog.append(failure)

        // Keep only the last 20 failures.
        if failureLog.count > 20 {
            failureLog = Array(failureLog.suffix(20))
        }
    }
}

// MARK: - InferenceProgress

/// Progress update sent during a multi-source inference attempt. Sendable.
struct InferenceProgress: Sendable {
    let source: LocalFallbackManager.InferenceSource
    let attempt: Int
    let maxRetries: Int
    let status: InferenceStatus

    /// Human-readable description of the current state.
    var description: String {
        switch status {
        case .attempting:
            return "Trying \(source.displayName) (attempt \(attempt)/\(maxRetries))"
        case .retrying(let reason):
            return "Retrying \(source.displayName): \(reason)"
        case .success:
            return "\(source.displayName) succeeded"
        case .exhausted:
            return "\(source.displayName) exhausted — trying next source"
        case .fallback:
            return "Falling back to \(source.displayName)"
        }
    }
}

/// The current status of an inference attempt. Sendable.
enum InferenceStatus: Sendable {
    case attempting
    case retrying(String)  // reason for retry
    case success
    case exhausted
    case fallback
}

// MARK: - Errors

/// Errors specific to the LocalFallbackManager. Sendable.
enum InferenceFallbackError: Error, Sendable, CustomStringConvertible {
    case unknown
    case localEngineUnavailable(String)
    case cloudNotImplemented(String)
    case allSourcesFailed(String)

    var description: String {
        switch self {
        case .unknown:
            return "Unknown inference error"
        case .localEngineUnavailable(let detail):
            return "Local engine unavailable: \(detail)"
        case .cloudNotImplemented(let detail):
            return "Cloud inference not implemented: \(detail)"
        case .allSourcesFailed(let detail):
            return "All inference sources failed:\n\(detail)"
        }
    }
}
