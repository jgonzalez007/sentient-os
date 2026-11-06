//
//  ModelLocator.swift
//  Sentient OS macOS
//
//  Phase 2.1 — Model Versioning: Discovers, catalogs, and validates available models on disk.
//  Scans the model directory for .litertlm files, parses metadata from filenames, reads file
//  sizes for disk-space checks, and caches results with a refresh mechanism.
//
//  Integration:
//   - ModelLocator.shared.availableModels → full catalog
//   - ModelLocator.shared.defaultModel    → the canonical gemma-4-E4B-it model
//   - ModelLocator.shared.validate(_: )   → async verification before engine use
//   - ModelLocator.shared.refresh()       → rescans and invalidates cache
//
//  The model directory is ~/Library/Application Support/SentientOS/Models/
//  Resolution order (used by both Engine and ModelDownload):
//   1. SENTIENT_MODEL_PATH env override (headless/self-test runs)
//   2. The app bundle
//   3. Application Support/SentientOS/Models/
//   4. DEBUG: repo root next to .xcodeproj
//

import Foundation

@Observable
final class ModelLocator {

    // MARK: - ModelInfo

    /// Parsed metadata from a .litertlm file. Sendable so it can cross actor boundaries.
    struct ModelInfo: Sendable, Identifiable {
        let id = UUID()
        let name: String             // e.g., "gemma-4-E4B-it"
        let path: URL
        let fileSize: Int64
        let lastModified: Date
        let version: String?         // e.g., "4.0"
        let architecture: String?    // e.g., "gemma", "llama", "mistral"
        let quantization: String?    // e.g., "E4B", "Q4_0", "Q8_0"
        let isDefault: Bool          // matches the canonical model name

        /// Human-readable label for UI display.
        var displayName: String {
            [version, architecture, quantization].compactMap { $0 }.joined(separator: " · ")
                .isEmpty ? name : [version ?? name, quantization].compactMap { $0 }.joined(separator: " ")
        }

        /// Estimated VRAM needed in GB (rough heuristic based on quantization).
        var estimatedVRAMGB: Double {
            switch quantization {
            case "E2B":    return 1.5
            case "E4B":    return 3.5
            case "E4B_MoE": return 5.0
            case "Q4_0":   return 3.0
            case "Q4_1":   return 3.5
            case "Q5_0":   return 3.5
            case "Q5_1":   return 4.0
            case "Q8_0":   return 6.5
            default:       return 4.0
            }
        }
    }

    // MARK: - Shared

    static let shared = ModelLocator()
    static let modelFileName = "gemma-4-E4B-it.litertlm"

    private init() {}

    // MARK: - Discoverable Models

    /// Scans the model directory recursively for .litertlm files, parses metadata, and returns
    /// the full catalog sorted by last modified (newest first). The result is cached until
    /// `refresh()` is called.
    var availableModels: [ModelInfo] {
        modelsCache { refresh() }
    }

    /// The default model (e.g., gemma-4-E4B-it.litertlm), or nil if not found.
    var defaultModel: ModelInfo? {
        availableModels.first { $0.name == ModelLocator.modelFileName.replacingOccurrences(of: ".litertlm", with: "") }
    }

    // MARK: - Public API

    /// Resolve the active model file path using the standard resolution order.
    /// Returns nil if no model is found anywhere.
    static func resolve() -> String? {
        let fm = FileManager.default

        #if DEBUG
        // ENV override: headless/self-test runs.
        if let env = ProcessInfo.processInfo.environment["SENTIENT_MODEL_PATH"],
           fm.fileExists(atPath: env) {
            return env
        }
        #endif

        // Bundle-bundled model (shipped builds).
        if let bundled = Bundle.main.path(forResource: "gemma-4-E4B-it", ofType: "litertlm") {
            return bundled
        }

        // Application Support/SentientOS/Models/
        let appSupport = URL.sentientSupport
            .appendingPathComponent("Models/\(modelFileName)").path
        if fm.fileExists(atPath: appSupport) { return appSupport }

        #if DEBUG
        // Dev fallback: walk up from this source file to repo root.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent(modelFileName).path
            if fm.fileExists(atPath: candidate) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        #endif

        return nil
    }

    /// Validate that a model file is loadable — checks existence, minimum size (≥100 MB to
    /// rule out corruption), and returns true if all checks pass. This is the gate before
    /// passing a model path to Engine.load().
    ///
    /// For Gemma 4 E4B: the model is ~3.66 GB. A file under 100 MB is almost certainly
    /// a partial/corrupted download.
    func validate(_ model: ModelInfo) async -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: model.path.path) else { return false }
        guard model.fileSize >= 100_000_000 else { return false } // ≥ 100 MB
        // Best-effort: attempt to open the file for reading.
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let handle: FileHandle?
                do {
                    handle = try FileHandle(forReadingFrom: model.path)
                } catch {
                    cont.resume(returning: false)
                    return
                }
                handle?.close()
                cont.resume(returning: true)
            }
        }
    }

    /// Validate a raw path string (convenience for Engine.swift which holds a String, not ModelInfo).
    func validate(_ path: String) async -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return false }
        guard let attr = try? fm.attributesOfItem(atPath: path),
              let size = attr[.size] as? Int64,
              size >= 100_000_000 else { return false }
        return await validate(ModelInfo(
            name: path.lastPathComponent.replacingOccurrences(of: ".litertlm", with: ""),
            path: URL(fileURLWithPath: path),
            fileSize: size,
            lastModified: (attr[.modificationDate] as? Date) ?? .distantPast,
            version: nil,
            architecture: nil,
            quantization: nil,
            isDefault: path.lastPathComponent == ModelLocator.modelFileName
        ))
    }

    /// Refresh the model catalog: re-scan, re-parse, invalidate cache. Call after a download
    /// completes or a model is manually placed in the models directory.
    func refresh() {
        let fm = FileManager.default
        let modelsDir = URL.sentientSupport.appendingPathComponent("Models", isDirectory: true)
        try? fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let infos: [ModelInfo] = (try? fm.contentsOfDirectory(
            at: modelsDir, includingPropertiesForKeys: [.sizeKey, .modificationDateKey]
        ) ?? []).filter { $0.pathExtension == "litertlm" }.map { url in
            let meta = parseMetadata(from: url.lastPathComponent)
            return ModelInfo(
                name: meta.name,
                path: url,
                fileSize: (try? url.resourceValues(forKeys: [.sizeKey]).size) ?? 0,
                lastModified: (try? url.resourceValues(forKeys: [.modificationDateKey]).modificationDate) ?? .distantPast,
                version: meta.version,
                architecture: meta.architecture,
                quantization: meta.quantization,
                isDefault: url.lastPathComponent == ModelLocator.modelFileName
            )
        }

        // Sorted newest-first for the UI.
        modelsCacheLock.withLock { modelsCacheData = infos.sorted { $0.lastModified > $1.lastModified } }
    }

    // MARK: - Internals

    private var modelsCacheData: [ModelInfo] = []
    private var modelsCacheTimestamp: Date?
    private let modelsCacheLock = NSLock()

    /// Read cached models, refreshing if the cache is stale (older than 5 minutes).
    /// The cache lives on the main thread to match @Observable access patterns.
    private func modelsCache(_ refresh: () -> Void) -> [ModelInfo] {
        modelsCacheLock.lock()
        defer { modelsCacheLock.unlock() }

        if let last = modelsCacheTimestamp,
           Date().timeIntervalSince(last) < 300 { // 5-minute TTL
            return modelsCacheData
        }
        refresh()
        return modelsCacheData
    }

    /// Parse metadata from a filename like "gemma-4-E4B-it.litertlm".
    /// Splits on "-" (ignoring the final ".litertlm" extension) and matches known patterns.
    private static func parseMetadata(from filename: String) -> (name: String, version: String?, architecture: String?, quantization: String?) {
        var name = filename
        if name.hasSuffix(".litertlm") {
            name = String(name.dropLast(11))
        }

        let parts = name.components(separatedBy: "-")

        // Architecture: first token, matched against known families.
        var architecture: String?
        let first = parts.first?.lowercased() ?? ""
        switch first {
        case "gemma":   architecture = "gemma"
        case "llama":   architecture = "llama"
        case "mistral": architecture = "mistral"
        case "phi":     architecture = "phi"
        case "qwen":    architecture = "qwen"
        default:        architecture = first.isEmpty ? nil : first
        }

        // Version: look for a digit sequence (e.g., "4" from "gemma-4-E4B").
        var version: String?
        for part in parts {
            let digits = part.filter { $0.isNumber }
            if digits.count >= 1, digits.count <= 3, !digits.isEmpty {
                version = digits
                break
            }
        }

        // Quantization: look for known patterns like E4B, Q4_0, Q8_0, E2B.
        var quantization: String?
        let quantPatterns = ["E4B_MoE", "E4B", "Q8_0", "Q5_1", "Q5_0", "Q4_1", "Q4_0", "E2B"]
        for pat in quantPatterns {
            if parts.contains(where: { $0.hasPrefix(pat) }) {
                quantization = pat
                break
            }
        }

        return (name, version, architecture, quantization)
    }
}

// MARK: - Default Model Name

extension ModelLocator {
    /// The canonical model name that ModelLocator treats as "default".
    static var defaultModelName: String { "gemma-4-E4B-it" }
}
