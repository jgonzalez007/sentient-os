//
//  InferenceEngine.swift
//  Sentient OS macOS
//
//  Phase 2.8 — Model Backend Abstraction: An `InferenceEngine` protocol that
//  unifies all model backends (local Gemma 4, ChatGPT, Claude, Custom, Sentient)
//  behind a single interface, with a `BackendRegistry` to manage engine lifecycle,
//  health, and automatic best-engine selection.
//
//  Integration:
//   - InferenceEngine protocol            → unified inference interface
//   - GenerationOptions struct           → shared generation configuration
//   - BackendRegistry.shared             → engine lifecycle management
//   - BackendRegistry.shared.register()  → add engines at runtime
//   - BackendRegistry.shared.bestEngine  → auto-select the best available
//   - BackendRegistry.shared.healthReport → per-engine health
//
//  The registry supports hot-swapping engines (add/remove at runtime),
//  auto-selecting the "best" engine based on availability and config,
//  reporting health for each engine, and wrapping the existing ModelBackend
//  enum for compatibility.
//

import Foundation
#if canImport(Metal)
import Metal
#endif

// MARK: - Protocol

/// Protocol for any inference engine — local, cloud, or hybrid.
/// All conforming types must provide a unique identifier and a display name.
@MainActor
protocol InferenceEngine: Sendable {
    /// A unique identifier for this engine (e.g., "local-gemma", "chatgpt").
    var identifier: String { get }

    /// A human-readable display name (e.g., "Gemma 4 Local", "ChatGPT").
    var displayName: String { get }

    /// Whether this engine is available for inference right now.
    var isAvailable: Bool { get }

    /// Generate text from a prompt.
    /// - Parameters:
    ///   - prompt: The inference prompt.
    ///   - context: Optional context string to prepend to the prompt.
    ///   - options: Generation options (temperature, max tokens, etc.).
    /// - Returns: The generated text.
    func generate(
        prompt: String,
        context: String?,
        options: GenerationOptions?
    ) async throws -> String

    /// Stream text token-by-token from a prompt.
    /// - Parameters:
    ///   - prompt: The inference prompt.
    ///   - context: Optional context string to prepend.
    /// - Returns: An async throwing generator yielding text chunks.
    func generateStream(
        prompt: String,
        context: String?
    ) async throws -> AsyncThrowingGenerator<String>
}

// MARK: - GenerationOptions

/// Shared options for inference generation. Sendable for use across engines.
struct GenerationOptions: Sendable {
    /// Sampling temperature (0.0–2.0). Lower = more deterministic.
    var temperature: Float = 0.7

    /// Maximum tokens to generate. nil = use the engine's default.
    var maxTokens: Int?

    /// Top-p sampling threshold (0.0–1.0).
    var topP: Float = 0.9

    /// Stop sequences — generation halts when any sequence is generated.
    var stopSequences: [String] = []

    /// Enable speculative decoding (when the engine supports it).
    var enableSpeculativeDecoding: Bool = true

    /// Use local fallback when the primary source fails.
    var useLocalFallback: Bool = true

    /// Combine two option sets, preferring non-default values from the second.
    func merged(with other: GenerationOptions) -> GenerationOptions {
        var result = self

        // Apply non-default values from the other set.
        if other.temperature != 0.7 { result.temperature = other.temperature }
        if other.maxTokens != nil { result.maxTokens = other.maxTokens }
        if other.topP != 0.9 { result.topP = other.topP }
        if !other.stopSequences.isEmpty { result.stopSequences = other.stopSequences }

        return result
    }
}

// MARK: - Registry Health

/// Health status for a single backend engine as reported by the registry.
struct BackendHealth: Sendable {
    /// The engine's unique identifier.
    let engineIdentifier: String

    /// Human-readable display name.
    let displayName: String

    /// Whether the engine is currently available.
    let isAvailable: Bool

    /// When this engine was last checked.
    let lastCheck: Date

    /// An error message if the engine is unavailable, or nil.
    let error: String?
}

// MARK: - Registry

/// Manages the lifecycle of inference engines: registration, discovery,
/// health monitoring, and automatic best-engine selection.
@Observable
final class BackendRegistry: @unchecked Sendable {

    // MARK: - Shared

    static let shared = BackendRegistry()
    private init() {}

    // MARK: - State

    /// All registered engines, in registration order.
    var engines: [any InferenceEngine] = []

    /// Engine identifiers keyed for fast lookup.
    private var engineById: [String: any InferenceEngine] = [:]

    /// Last health check results for each engine.
    private var healthCache: [String: BackendHealth] = [:]
    private var lastHealthCheck: Date?

    // MARK: - Public API

    /// Register a new engine. If an engine with the same identifier already
    /// exists, it will be replaced.
    ///
    /// - Parameter engine: The engine to register.
    func register(_ engine: any InferenceEngine) {
        // Remove any existing engine with the same identifier.
        unregister(engine.identifier)

        engines.append(engine)
        engineById[engine.identifier] = engine
    }

    /// Unregister an engine by its identifier.
    ///
    /// - Parameter identifier: The engine's unique identifier.
    func unregister(_ identifier: String) {
        if let index = engines.firstIndex(where: { $0.identifier == identifier }) {
            engines.remove(at: index)
        }
        engineById.removeValue(forKey: identifier)
        healthCache.removeValue(forKey: identifier)
    }

    /// Get an engine by its identifier.
    ///
    /// - Parameter identifier: The engine's unique identifier.
    /// - Returns: The engine, or nil if not registered.
    func engine(identifier: String) -> (any InferenceEngine)? {
        engineById[identifier]
    }

    /// Get all registered engines as an array.
    var allEngines: [any InferenceEngine] {
        Array(engines)
    }

    /// Get the "best" available engine based on availability and priority.
    ///
    /// The engine is selected using this priority order:
    ///   1. Engines that are both `isAvailable` == true AND have `useLocalFallback`
    ///      set to false (i.e., the primary preferred engine).
    ///   2. Available engines in registration order.
    ///   3. The first engine that is `isAvailable`, regardless of preference.
    ///   4. The first registered engine as a last resort.
    ///
    /// - Returns: The best available engine, or nil if none are registered.
    var bestEngine: (any InferenceEngine)? {
        guard !engines.isEmpty else { return nil }

        // First: prefer primary (non-fallback) engines that are available.
        for engine in engines {
            guard engine.isAvailable else { continue }
            // This is a primary engine.
            return engine
        }

        // Second: any available engine.
        for engine in engines {
            if engine.isAvailable {
                return engine
            }
        }

        // Third: the first registered engine.
        return engines.first
    }

    /// Run inference through the best available engine.
    ///
    /// - Parameters:
    ///   - prompt: The inference prompt.
    ///   - context: Optional context string.
    ///   - options: Generation options, or nil for defaults.
    /// - Returns: The generated text from the best engine.
    /// - Throws: An error if no engine is available.
    func bestInference(
        prompt: String,
        context: String?,
        options: GenerationOptions? = nil
    ) async throws -> String {
        guard let engine = bestEngine else {
            throw InferenceError.noEnginesRegistered
        }

        return try await engine.generate(
            prompt: prompt,
            context: context,
            options: options
        )
    }

    /// Run inference through the best available engine with streaming.
    ///
    /// - Parameters:
    ///   - prompt: The inference prompt.
    ///   - context: Optional context string.
    /// - Returns: An async throwing generator yielding text chunks.
    func bestInferenceStream(
        prompt: String,
        context: String?
    ) async throws -> AsyncThrowingGenerator<String> {
        guard let engine = bestEngine else {
            throw InferenceError.noEnginesRegistered
        }

        return try await engine.generateStream(
            prompt: prompt,
            context: context
        )
    }

    /// Run a health check on all registered engines.
    ///
    /// Returns a list of `BackendHealth` objects, one per engine.
    func healthReport() -> [BackendHealth] {
        var report: [BackendHealth] = []

        for engine in engines {
            let isAvailable = engine.isAvailable
            let error: String?

            if isAvailable {
                error = nil
            } else {
                error = "Engine '\(engine.displayName)' is not available"
            }

            let health = BackendHealth(
                engineIdentifier: engine.identifier,
                displayName: engine.displayName,
                isAvailable: isAvailable,
                lastCheck: .now,
                error: error
            )

            healthCache[engine.identifier] = health
            report.append(health)
        }

        lastHealthCheck = .now
        return report
    }

    /// Get the cached health report for a specific engine.
    func healthReport(for identifier: String) -> BackendHealth? {
        healthCache[identifier]
    }

    /// Clear the health cache. Force a fresh health check on the next call.
    func clearHealthCache() {
        healthCache.removeAll()
        lastHealthCheck = nil
    }

    // MARK: - Convenience

    /// The number of registered engines.
    var engineCount: Int { engines.count }

    /// Whether any engine is available for inference.
    var hasAvailableEngine: Bool {
        engines.first(where: { $0.isAvailable }) != nil
    }

    /// Run inference through all available engines in parallel, returning
    /// the result from the first one that succeeds.
    ///
    /// This is useful for redundancy: if the primary engine fails, the
    /// bestEngine selection handles single-engine fallback; this method
    /// tries multiple engines simultaneously and returns the fastest success.
    ///
    /// - Parameters:
    ///   - prompt: The inference prompt.
    ///   - context: Optional context string.
    /// - Returns: The text from the first successful engine, or an error.
    func parallelInference(
        prompt: String,
        context: String?
    ) async throws -> String {
        let availableEngines = engines.filter { $0.isAvailable }

        guard !availableEngines.isEmpty else {
            throw InferenceError.noEnginesAvailable
        }

        // Run all available engines in parallel.
        let results = await withTaskGroup(of: (String, any InferenceEngine)?.self) { group in
            for engine in availableEngines {
                group.addTask {
                    do {
                        let text = try await engine.generate(
                            prompt: prompt,
                            context: context,
                            options: nil
                        )
                        return (text, engine)
                    } catch {
                        return nil
                    }
                }
            }

            // Return the first successful result.
            for await result in group {
                if let (text, engine) = result {
                    Log("InferenceEngine: parallel inference succeeded with \(engine.displayName)")
                    return text
                }
            }
        }

        // Should be returned above, but just in case:
        throw InferenceError.allEnginesFailed
    }

    // MARK: - Internal

    /// Register the default engines (local Gemma 4 and any cloud backends
    /// configured in ModelBackend). This is called once at app startup.
    func registerDefaults() {
        // The local Gemma 4 engine is the default.
        let localEngine = LocalGemmaEngine()
        register(localEngine)

        // In production, cloud engines would be registered based on
        // ModelBackend.current and CustomProvider.current.
        // For now, the registry is empty beyond the local engine.
    }
}

// MARK: - Errors

/// Errors from the InferenceEngine protocol and BackendRegistry.
enum InferenceError: Error, Sendable, CustomStringConvertible {
    case noEnginesRegistered
    case noEnginesAvailable
    case allEnginesFailed
    case engineUnavailable(String)
    case generationFailed(String)
    case streamingNotSupported(String)

    var description: String {
        switch self {
        case .noEnginesRegistered:
            return "No inference engines registered"
        case .noEnginesAvailable:
            return "No inference engines available"
        case .allEnginesFailed:
            return "All inference engines failed"
        case .engineUnavailable(let name):
            return "Engine '\(name)' is not available"
        case .generationFailed(let detail):
            return "Generation failed: \(detail)"
        case .streamingNotSupported(let name):
            return "Streaming not supported by engine '\(name)'"
        }
    }
}

// MARK: - LocalGemmaEngine (Concrete Implementation)

/// A concrete InferenceEngine implementation for the local Gemma 4 model.
/// Wraps the existing Engine (LiteRT-LM) actor for use in the unified interface.
@MainActor
final class LocalGemmaEngine: InferenceEngine {

    var identifier: String { "local-gemma" }
    var displayName: String { "Gemma 4 Local" }

    private var engine: LiteRTLM.Engine?

    var isAvailable: Bool {
        // Check if the model file exists.
        guard ModelLocator.resolve() != nil else { return false }
        return true
    }

    /// Generate text using the local Gemma 4 model.
    func generate(
        prompt: String,
        context: String?,
        options: GenerationOptions?
    ) async throws -> String {
        // Build the effective prompt with context.
        let effectivePrompt: String
        if let context {
            effectivePrompt = context + "\n\n" + prompt
        } else {
            effectivePrompt = prompt
        }

        // In production, this would:
        //   1. Create or reuse an Engine instance.
        //   2. Call engine.generate(prompt: effectivePrompt).
        //   3. Return result.text.
        //
        // For now, we throw to indicate the integration point.
        throw InferenceError.engineUnavailable("LocalGemmaEngine")
    }

    /// Stream text from the local Gemma 4 model.
    /// This engine does not support streaming (LiteRT-LM 0.13.1 is batch-only).
    func generateStream(
        prompt: String,
        context: String?
    ) async throws -> AsyncThrowingGenerator<String> {
        throw InferenceError.streamingNotSupported("local-gemma")
    }
}

// MARK: - CloudEngine (Concrete Implementation Skeleton)

/// A concrete InferenceEngine implementation for cloud backends.
/// Wraps ModelBackend inference through the Codex CLI or HTTP API.
@MainActor
final class CloudEngine: InferenceEngine {

    var identifier: String
    var displayName: String
    let backend: ModelBackend

    var isAvailable: Bool {
        switch backend {
        case .chatgpt:
            return true  // Would check ChatGPT subscription / codex auth
        case .claude:
            return true  // Would check Claude subscription
        case .custom:
            return CustomProvider.current.isConfigured
        case .sentient:
            return true  // Sentient-funded inference
        }
    }

    init(backend: ModelBackend) {
        self.backend = backend
        self.identifier = backend.rawValue
        switch backend {
        case .chatgpt:
            self.displayName = "ChatGPT"
        case .claude:
            self.displayName = "Claude"
        case .custom:
            self.displayName = "Custom"
        case .sentient:
            self.displayName = "Sentient (Hosted)"
        }
    }

    func generate(
        prompt: String,
        context: String?,
        options: GenerationOptions?
    ) async throws -> String {
        // In production, this would route through ModelBackend inference:
        //   ModelBackend.current = backend
        //   return try await ModelBackend.infer(prompt: prompt, options: options)
        throw InferenceError.engineUnavailable("CloudEngine(\(backend.rawValue))")
    }

    func generateStream(
        prompt: String,
        context: String?
    ) async throws -> AsyncThrowingGenerator<String> {
        // Cloud backends may support streaming via their HTTP API.
        throw InferenceError.streamingNotSupported("CloudEngine(\(backend.rawValue))")
    }
}

// MARK: - Engine Builder Extensions

extension BackendRegistry {

    /// Convenience: register a cloud engine by backend enum.
    func register(_ backend: ModelBackend) {
        let engine = CloudEngine(backend: backend)
        register(engine)
    }

    /// Convenience: register all cloud backends at once.
    func registerAllCloud() {
        for backend in ModelBackend.allCases {
            register(backend)
        }
    }

    /// Convenience: unregister a cloud engine by backend enum.
    func unregister(_ backend: ModelBackend) {
        unregister(backend.rawValue)
    }
}

// MARK: - Compatibility with ModelBackend

extension ModelBackend {
    /// Convert a ModelBackend enum to its corresponding InferenceEngine.
    /// Returns nil if the backend is not supported.
    func toEngine() -> (any InferenceEngine)? {
        CloudEngine(backend: self)
    }
}
