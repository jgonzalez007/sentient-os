//
//  DeprecationManager.swift
//  Sentient OS macOS  ·  Ingestion/
//
//  Phase 1.8 — Connector Deprecation Path
//
//  Manages the lifecycle of deprecated connectors with policy-driven sunsetting.
//  Provides a framework for gracefully retiring old connectors while maintaining
//  backward compatibility and guiding users through migration.
//
//  Key methods:
//   - register(policy:)           — register a deprecation policy for a connector
//   - shouldBlock(sourceKind:)    — check if a connector should be blocked
//   - deprecationMessage(for:)    — get user-facing deprecation message
//   - migrate(from:to:)           — register a migration path
//   - shouldCleanup(sourceKind:)  — check if sunset grace period has passed
//   - blockedConnectors()         — list all currently blocked connectors
//   - sunsetConnectors()          — list all connectors past sunset
//
//  Policies are loaded from a bundled JSON config file and can be extended
//  programmatically at runtime. Active connectors past sunset are blocked
//  with graceful error messages. Deprecation messages and migration guide
//  links are shown to users via the UI.
//
//  Doc: Ingestion/Documentation\ -\ Ingestion\ Pipeline.md
//

import Foundation
import os

// MARK: - Deprecation Manager

/// Manages deprecation policies for MCP connectors. Each connector can have an
/// associated deprecation timeline with a sunset date, migration guidance, and
/// user-facing messaging.
///
/// ## Lifecycle Stages
///
/// 1. **Active** — connector works normally
/// 2. **Deprecated** (`Date() > deprecationDate && Date() <= sunsetDate`) — connector works
///    but shows warnings to users; migration guide is available
/// 3. **Sunset** (`Date() > sunsetDate`) — connector is blocked for new connections;
///    existing data is preserved; users are guided to the replacement
/// 4. **Removed** (after 30-day grace past sunset) — connector data is cleaned up
///
/// ## Configuration
///
/// Policies can be loaded from a bundled JSON config file:
///
/// ```json
/// {
///   "policies": [
///     {
///       "sourceKind": "gmail-v1",
///       "deprecationDate": "2026-11-01T00:00:00Z",
///       "sunsetDate": "2027-05-01T00:00:00Z",
///       "replacementSourceKind": "gmail",
///       "migrationGuideURL": "https://docs.sentientos.com/migrate/gmail-v1",
///       "message": "Gmail v1 connector is deprecated. Please migrate to Gmail v2."
///     }
///   ]
/// }
/// ```
///
/// The config file should be bundled in the app's resource directory and loaded
/// at startup via `loadFromBundle()`.
///
/// ## Usage
///
/// ```swift
/// let manager = DeprecationManager.shared
///
/// // Check if a connector should be blocked
/// if manager.shouldBlock(sourceKind: .gmailV1) {
///     showBlockingAlert()
/// }
///
/// // Get deprecation message for UI display
/// if let message = manager.deprecationMessage(for: .gmailV1) {
///     displayMessage(message)
/// }
///
/// // Register a new migration policy
/// manager.migrate(from: .gmailV1, to: .gmail, sunset: Date().addingTimeInterval(30 * 86400))
/// ```
@Observable
final class DeprecationManager: Sendable {
    static let shared = DeprecationManager()

    private let logger = Logger(subsystem: "com.josegonzalez.sentient-os", category: "Deprecation")

    private init() {
        // Load default policies from bundled config
        loadFromBundle()
    }

    // MARK: - Policy Definition

    /// A deprecation policy for a single connector source kind.
    ///
    /// ## Fields
    ///
    /// - `sourceKind` — the connector identifier this policy applies to
    /// - `deprecationDate` — when the connector is marked as deprecated
    /// - `sunsetDate` — when the connector is removed entirely
    /// - `replacementSourceKind` — the recommended replacement connector
    /// - `migrationGuideURL` — URL to a migration guide document
    /// - `message` — user-facing message explaining the deprecation
    struct DeprecationPolicy: Sendable, Codable, Identifiable {
        let id: UUID
        let sourceKind: SourceKind
        let deprecationDate: Date
        let sunsetDate: Date
        let replacementSourceKind: SourceKind?
        let migrationGuideURL: URL?
        let message: String

        /// Whether the connector is currently in the deprecated window
        /// (past deprecation date but not yet past sunset).
        var isActive: Bool {
            let now = Date()
            return now > deprecationDate && now <= sunsetDate
        }

        /// Whether the connector has passed its sunset date and should be blocked.
        var isSunset: Bool {
            Date() > sunsetDate
        }

        /// Days remaining until the connector is fully sunset.
        /// Returns `nil` if already sunset.
        var daysUntilSunset: Int? {
            let calendar = Calendar.current
            let components = calendar.dateComponents([.day], from: Date(), to: sunsetDate)
            guard let days = components.day, !isSunset else { return nil }
            return days
        }

        /// Whether the connector has been past sunset for more than the grace period.
        var isPastGracePeriod: Bool {
            let graceEndDate = sunsetDate.addingTimeInterval(30 * 86400)
            return Date() > graceEndDate
        }

        /// The grace period end date (30 days after sunset).
        var gracePeriodEnd: Date {
            sunsetDate.addingTimeInterval(30 * 86400)
        }
    }

    // MARK: - Policy Store

    /// The registered deprecation policies.
    private(set) var policies: [DeprecationPolicy] = []

    // MARK: - Public API

    /// Register a new deprecation policy.
    ///
    /// - Parameter policy: The deprecation policy to register.
    func register(policy: DeprecationPolicy) {
        // Replace existing policy for the same source kind
        policies.removeAll { $0.sourceKind == policy.sourceKind }
        policies.append(policy)
        logger.info("Registered deprecation policy for \(policy.sourceKind.rawValue)")
    }

    /// Check if a connector should be blocked (past sunset date).
    ///
    /// Blocked connectors are prevented from new connections and reads.
    /// Existing data is preserved; only new ingestion is blocked.
    ///
    /// - Parameter sourceKind: The connector to check.
    /// - Returns: `true` if the connector is past its sunset date.
    func shouldBlock(sourceKind: SourceKind) -> Bool {
        guard let policy = findPolicy(for: sourceKind) else {
            return false // No policy = not blocked
        }
        return policy.isSunset
    }

    /// Get the user-facing deprecation message for a connector.
    ///
    /// - Parameter sourceKind: The connector to get the message for.
    /// - Returns: The deprecation message, or `nil` if no policy exists.
    func deprecationMessage(for sourceKind: SourceKind) -> String? {
        findPolicy(for: sourceKind)?.message
    }

    /// Get the replacement source kind for a deprecated connector.
    ///
    /// - Parameter sourceKind: The deprecated connector.
    /// - Returns: The recommended replacement, or `nil` if not specified.
    func replacement(for sourceKind: SourceKind) -> SourceKind? {
        findPolicy(for: sourceKind)?.replacementSourceKind
    }

    /// Get the migration guide URL for a deprecated connector.
    ///
    /// - Parameter sourceKind: The deprecated connector.
    /// - Returns: The migration guide URL, or `nil` if not specified.
    func migrationGuideURL(for sourceKind: SourceKind) -> URL? {
        findPolicy(for: sourceKind)?.migrationGuideURL
    }

    /// Register a migration policy: deprecated from → to.
    ///
    /// Creates a policy with a 90-day deprecation window and a 6-month sunset window
    /// after the deprecation date. This is the standard migration policy for
    /// connector replacements.
    ///
    /// - Parameters:
    ///   - from: The deprecated connector source kind.
    ///   - to: The replacement connector source kind.
    ///   - deprecationDate: When deprecation begins (default: now).
    ///   - sunsetDate: When connector is fully sunset (default: 6 months from now).
    ///   - message: User-facing message (auto-generated if nil).
    ///   - guideURL: Migration guide URL (default: docs site).
    func migrate(
        from: SourceKind,
        to: SourceKind,
        deprecationDate: Date = Date(),
        sunsetDate: Date? = nil,
        message: String? = nil,
        guideURL: URL? = nil
    ) {
        let actualSunset = sunsetDate ?? deprecationDate.addingTimeInterval(6 * 30 * 86400) // ~6 months
        let actualMessage = message ?? "The \(from.rawValue) connector is deprecated. Please migrate to \(to.rawValue)."
        let guide = guideURL ?? URL(string: "https://docs.sentientos.com/migrate/\(from.rawValue)")

        let policy = DeprecationPolicy(
            id: UUID(),
            sourceKind: from,
            deprecationDate: deprecationDate,
            sunsetDate: actualSunset,
            replacementSourceKind: to,
            migrationGuideURL: guide,
            message: actualMessage
        )

        register(policy: policy)
        logger.info("Migrated \(from.rawValue) → \(to.rawValue), sunset \(actualSunset.formatted())")
    }

    /// Check if a connector should be cleaned up (past sunset grace period of 30 days).
    ///
    /// Cleaned-up connectors have their local data and cached state removed.
    /// This is a destructive operation — callers should confirm with the user.
    ///
    /// - Parameter sourceKind: The connector to check.
    /// - Returns: `true` if the connector is past its sunset grace period.
    func shouldCleanup(sourceKind: SourceKind) -> Bool {
        guard let policy = findPolicy(for: sourceKind) else {
            return false
        }
        return policy.isPastGracePeriod
    }

    /// List all connectors that are currently blocked (past sunset).
    ///
    /// - Returns: Array of blocked source kinds.
    func blockedConnectors() -> [SourceKind] {
        policies.filter(\.isSunset).map(\.sourceKind)
    }

    /// List all connectors that are currently in the sunset grace period
    /// (past deprecation date but not yet past grace end).
    ///
    /// - Returns: Array of connectors in sunset grace period.
    func sunsetGraceConnectors() -> [SourceKind] {
        policies.filter { !$0.isSunset || $0.isPastGracePeriod }.map(\.sourceKind)
    }

    /// List all connectors currently in the deprecation window.
    ///
    /// - Returns: Array of currently deprecated (but not yet sunset) source kinds.
    var activeDeprecations: [SourceKind] {
        policies.filter(\.isActive).map(\.sourceKind)
    }

    // MARK: - Bundled Configuration

    /// Load default deprecation policies from a bundled JSON config file.
    ///
    /// The config file should be named `deprecation-config.json` and placed in
    /// the app's main bundle resources directory. It contains an array of policies
    /// in the standard JSON format.
    ///
    /// - Parameter bundle: The bundle to load from (defaults to the main bundle).
    func loadFromBundle(bundle: Bundle = .main) {
        let configFile = "deprecation-config.json"
        guard let url = bundle.url(forResource: configFile, withExtension: nil) else {
            logger.debug("No bundled deprecation config found; using defaults")
            loadDefaults()
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().loadConfig(from: data)
            for policy in config.policies {
                register(policy: policy)
            }
            logger.info("Loaded \(config.policies.count) deprecation policy/policies from bundle")
        } catch {
            logger.warning("Failed to load deprecation config from bundle: \(error.localizedDescription); using defaults")
            loadDefaults()
        }
    }

    /// Save current policies to a bundled config file.
    ///
    /// - Parameter path: The file path to save to (defaults to `~/Library/Application Support/SentientOS/deprecation-config.json`).
    func saveToDisk(path: String? = nil) {
        let targetPath = path ?? defaultConfigPath()
        let directory = (targetPath as NSString).deletingLastPathComponent

        do {
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: directory) {
                try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)
            }

            let data = try JSONEncoder().encode(SavedConfig(policies: policies))
            try data.write(to: URL(fileURLWithPath: targetPath), options: .atomicWrite)
            logger.info("Saved \(policies.count) deprecation policies to \(targetPath)")
        } catch {
            logger.error("Failed to save deprecation config: \(error.localizedDescription)")
        }
    }

    /// Load policies from a local config file on disk.
    ///
    /// - Parameter path: The file path to load from.
    func loadFromDisk(path: String? = nil) {
        let targetPath = path ?? defaultConfigPath()
        let fileURL = URL(fileURLWithPath: targetPath)

        do {
            let data = try Data(contentsOf: fileURL)
            let config = try JSONDecoder().decode(SavedConfig.self, from: data)
            policies.removeAll()
            for policy in config.policies {
                register(policy: policy)
            }
            logger.info("Loaded \(config.policies.count) deprecation policies from disk")
        } catch {
            logger.warning("Failed to load deprecation config from disk: \(error.localizedDescription)")
        }
    }

    // MARK: - Defaults

    /// Load built-in default policies. These are sensible defaults for connectors
    /// that don't have explicit policies and should not be blocked.
    private func loadDefaults() {
        // No default policies — all connectors are active by default.
        // Policies must be explicitly registered to enable deprecation.
        logger.info("No bundled defaults; all connectors active by default")
    }

    /// The default path for the on-disk deprecation config file.
    private func defaultConfigPath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("SentientOS").appendingPathComponent("deprecation-config.json").path
    }

    // MARK: - Internal

    /// Find a policy by source kind.
    private func findPolicy(for sourceKind: SourceKind) -> DeprecationPolicy? {
        policies.first { $0.sourceKind == sourceKind }
    }
}

// MARK: - Source Kind

/// The canonical source kind for a connector. Used by `DeprecationManager` to
/// reference specific connectors by their canonical identifier.
///
/// This enum covers all built-in MCP connectors and can be extended for
/// custom connectors.
enum SourceKind: String, Sendable, Codable, CaseIterable {
    // Built-in MCP connectors
    case gmail
    case googleCalendar
    case googleDrive
    case slack
    case notion
    case granola
    case outlookMail
    case outlookCalendar
    case appleCalendar
    case appleMail
    case iMessage
    case whatsapp
    case notes
    case files
    case siYuan
    case directMCP

    // Hosted and custom
    case hosted
    case custom
    case unknown
}

// MARK: - Persistent Config

/// A saveable configuration of deprecation policies for disk persistence.
struct SavedConfig: Codable, Sendable {
    let policies: [DeprecationPolicy]
}

// MARK: - JSON Encoder/Decoder Extensions

extension JSONDecoder {
    /// Decode a `SavedConfig` from data.
    func loadConfig(from data: Data) throws -> SavedConfig {
        try decode(SavedConfig.self, from: data)
    }
}

// MARK: - Deprecation Policy Factory

/// Convenience methods for creating common deprecation policy patterns.
enum DeprecationPolicyFactory {
    /// Create a standard deprecation policy with sensible defaults.
    ///
    /// - Parameters:
    ///   - sourceKind: The connector to deprecate.
    ///   - replacement: The replacement connector (optional).
    ///   - deprecationDate: When deprecation begins.
    ///   - sunsetDate: When connector is fully sunset.
    ///   - message: User-facing message.
    ///   - guideURL: Migration guide URL.
    static func standard(
        sourceKind: SourceKind,
        replacement: SourceKind? = nil,
        deprecationDate: Date = Date(),
        sunsetDate: Date,
        message: String? = nil,
        guideURL: URL? = nil
    ) -> DeprecationManager.DeprecationPolicy {
        let message = message ?? "The \(sourceKind.rawValue) connector is deprecated. Please migrate to the \(replacement?.rawValue ?? "new") connector."
        let guide = guideURL ?? URL(string: "https://docs.sentientos.com/migrate/\(sourceKind.rawValue)")

        return DeprecationManager.DeprecationPolicy(
            id: UUID(),
            sourceKind: sourceKind,
            deprecationDate: deprecationDate,
            sunsetDate: sunsetDate,
            replacementSourceKind: replacement,
            migrationGuideURL: guide,
            message: message
        )
    }

    /// Create a quick deprecation policy for hotfixes — short deprecation window
    /// and imminent sunset.
    static func emergency(
        sourceKind: SourceKind,
        deprecationDate: Date = Date(),
        sunsetDate: Date
    ) -> DeprecationManager.DeprecationPolicy {
        standard(
            sourceKind: sourceKind,
            deprecationDate: deprecationDate,
            sunsetDate: sunsetDate,
            message: "The \(sourceKind.rawValue) connector has a critical issue and is temporarily disabled. Use an alternative method."
        )
    }
}
