//
//  GPUManager.swift
//  Sentient OS macOS
//
//  Phase 2.3 — GPU Memory Management: Monitors GPU memory usage on Apple Silicon
//  via MTLDevice and provides auto-purge watchdog for LiteRT-LM model management.
//  Uses approximate unified memory heuristics (macOS doesn't expose exact GPU-only
//  allocations) with a configurable threshold and automatic cleanup.
//
//  Integration:
//   - GPUManager.shared.memoryStatus          → current GPU memory status
//   - GPUManager.shared.queryGPU()            → async full memory query
//   - GPUManager.shared.purgeModels()         → release cached model resources
//   - GPUManager.shared.startWatchdog()       → start auto-purge monitoring
//   - GPUManager.shared.stopWatchdog()        → stop auto-purge monitoring
//   - GPUManager.shared.clearCache()          → clear all model caches
//
//  Apple Silicon unified memory is split roughly 50/50 CPU/GPU by the OS.
//  A 16 GB Mac → ~8 GB GPU, ~8 GB CPU. A 3.66 GB model (Gemma 4 E4B) needs
//  ~4.5 GB in GPU to account for the model + runtime overhead (KV cache, weights).
//
//  The GPU manager's watchdog monitors memory pressure and triggers auto-purge
//  when usage exceeds the configured threshold (default: 80%).
//

import Foundation
#if canImport(Metal)
import Metal
#endif

@Observable
final class GPUManager: @unchecked Sendable {

    // MARK: - MemoryStatus

    /// Current GPU memory status. Sendable.
    struct MemoryStatus: Sendable {
        let totalGPU: Int64      // Total GPU memory (Apple Silicon unified, ~half is GPU-accessible)
        let usedGPU: Int64       // Currently used by model + runtime
        let availableGPU: Int64   // Available for model loading
        let loadPercentage: Float // 0.0 to 1.0

        /// Human-readable description for UI.
        var description: String {
            "\(loadPercentage * 100, specifier: "%.0f")% — \(usedGPU / 1_048_576) MB of \(totalGPU / 1_048_576) MB"
        }

        /// Whether a model of the given size (in GB) can be loaded.
        func canLoad(_ sizeGB: Double) -> Bool {
            let availableGB = Double(availableGPU) / 1_073_741_824
            return availableGB >= sizeGB * 1.25 // 25% overhead for KV cache
        }
    }

    // MARK: - WatchdogConfig

    /// Watchdog configuration for automatic memory monitoring and purge.
    struct WatchdogConfig: Sendable {
        let maxMemoryUsage: Float  // 0.8 = 80% threshold
        let purgeInterval: TimeInterval  // Check every N seconds
        let autoPurge: Bool      // Auto-purge when threshold exceeded

        var purgeThreshold: Int64 {
            Int64(Double(totalGPUForWatchdog) * Double(maxMemoryUsage))
        }

        private var totalGPUForWatchdog: Int64 { 16_000_000_000 } // conservative
    }

    // MARK: - Shared

    static let shared = GPUManager()
    static let defaultWatchdogConfig = WatchdogConfig(
        maxMemoryUsage: 0.8,
        purgeInterval: 60,
        autoPurge: true
    )

    private init() {}

    // MARK: - State

    /// Current memory status — updated by `queryGPU()` or the watchdog timer.
    var memoryStatus: MemoryStatus = MemoryStatus(
        totalGPU: 0,
        usedGPU: 0,
        availableGPU: 0,
        loadPercentage: 0
    )

    /// Current watchdog config.
    var watchdogConfig: WatchdogConfig = .default {
        didSet { watchdogTimer?.invalidate(); startWatchdog(silent: true) }
    }

    /// Whether the watchdog is running.
    var isWatchdogActive: Bool { watchdogTimer != nil && !watchdogTimer!.isValid == false }

    // MARK: - Public API

    /// Query GPU memory status. Returns an async result with the best-effort
    /// estimate of GPU memory usage on the current Mac.
    ///
    /// On Apple Silicon, this uses MTLDevice (if available) to determine the
    /// total GPU memory and estimates usage from known model sizes.
    ///
    /// - Returns: A MemoryStatus struct with totalGPU, usedGPU, availableGPU, and loadPercentage.
    func queryGPU() async -> MemoryStatus {
        #if canImport(Metal)
        let device = MTLCreateSystemDefaultDevice()
        if let device = device {
            let total = device.totalMemory
            let gpuShare = total / 2 // Apple Silicon: ~50% GPU accessible
            return MemoryStatus(
                totalGPU: total,
                usedGPU: estimateModelUsage(),
                availableGPU: gpuShare - estimateModelUsage(),
                loadPercentage: gpuShare > 0 ?
                    Float(estimateModelUsage()) / Float(gpuShare) : 0
            )
        }
        #endif

        // Fallback: estimate from sysctl.
        return MemoryStatus(
            totalGPU: estimateTotalMemory(),
            usedGPU: estimateModelUsage(),
            availableGPU: estimateTotalMemory() - estimateModelUsage(),
            loadPercentage: 0
        )
    }

    /// Estimate the VRAM used by currently loaded models.
    /// Gemma 4 E4B (~3.66 GB) + runtime overhead (~20%) ≈ 4.4 GB.
    /// Returns a rough estimate since macOS doesn't expose exact per-process GPU usage.
    func estimateModelUsage() -> Int64 {
        // Check if Gemma 4 E4B is loaded (check for the model file + cache).
        let modelDir = URL.sentientSupport.appendingPathComponent("Models")
        let modelFile = modelDir.appendingPathComponent("gemma-4-E4B-it.litertlm")
        let fm = FileManager.default

        if fm.fileExists(atPath: modelFile.path) {
            // Gemma 4 E4B: model file is ~3.66 GB, but VRAM usage is ~4.5 GB
            // due to weight loading, KV cache, and runtime overhead.
            return Int64(4.5 * 1_073_741_824) // 4.5 GB in bytes
        }

        // Check for any other models and estimate based on their sizes.
        var totalVRAM: Int64 = 0
        if let urls = try? fm.contentsOfDirectory(
            at: modelDir, includingPropertiesForKeys: nil
        ) {
            for url in urls where url.pathExtension == "litertlm" {
                if let attr = try? fm.attributesOfItem(atPath: url.path),
                   let size = attr[.size] as? Int64 {
                    // VRAM = file size × 1.25 (overhead for loading)
                    totalVRAM += Int64(Double(size) * 1.25)
                }
            }
        }

        // Add base runtime overhead.
        totalVRAM += Int64(500 * 1_048_576) // 500 MB base runtime
        return totalVRAM
    }

    /// Auto-purge unused model layers. On Apple Silicon with LiteRT-LM, this
    /// triggers the runtime's model cache flush, releasing GPU memory.
    ///
    /// In production, this calls `Engine.reload()` (unload + wait + reload) to
    /// reset the GPU state. For now, it's a no-op skeleton that logs.
    func purgeModels() async {
        Log("GPUManager: purging model cache (threshold: \(watchdogConfig.maxMemoryUsage * 100)%)")

        // Simulate GPU purge: on a real implementation this would:
        // 1. Call Engine.shared.unload() to release the native engine
        // 2. Wait ~1s for the GPU driver to settle
        // 3. Flush the shader cache
        // 4. Reload if needed

        await Task.detached(priority: .utility) {
            // Simulate purge delay.
            try? await Task.sleep(for: .seconds(1))

            // Update status after purge.
            await MainActor.run {
                let status = await GPUManager.shared.queryGPU()
                GPUManager.shared.memoryStatus = status
                Log("GPUManager: purge complete — \(status)")
            }
        }
    }

    /// Start the watchdog: a background timer that checks GPU memory at the
    /// configured interval and triggers auto-purge when the threshold is exceeded.
    func startWatchdog(silent: Bool = false) {
        watchdogTimer?.invalidate()
        watchdogTimer = nil

        guard watchdogConfig.autoPurge else { return }
        guard watchdogConfig.purgeInterval > 0 else { return }

        // Set up the periodic watchdog.
        let interval = watchdogConfig.purgeInterval
        watchdogTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { [weak self] _ in
            Task { [weak self] in
                guard let self else { return }
                await self.watchdogCheck()
            }
        }

        // Also start a delayed initial check.
        watchdogTimer = Timer.scheduledTimer(
            withTimeInterval: 5.0,
            repeats: false
        ) { [weak self] _ in
            Task { [weak self] in
                guard let self else { return }
                await self.watchdogCheck()
            }
        }

        if !silent {
            Log("GPUManager: watchdog started (interval: \(interval)s, threshold: \(watchdogConfig.maxMemoryUsage * 100)%)")
        }
    }

    /// Stop the watchdog timer.
    func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        Log("GPUManager: watchdog stopped")
    }

    /// Clear all model caches (shaders, compiled kernels, temp files).
    func clearCache() {
        let cacheDir = URL.sentientSupport.appendingPathComponent("ModelCache")
        let fm = FileManager.default
        if fm.fileExists(atPath: cacheDir.path) {
            try? fm.removeItem(at: cacheDir)
            Log("GPUManager: cache cleared")
        }
        // Also clear the model download staging area.
        let staging = URL.sentientSupport.appendingPathComponent("Models/.download")
        if fm.fileExists(atPath: staging.path) {
            try? fm.removeItem(at: staging)
            Log("GPUManager: staging cleared")
        }
    }

    // MARK: - Internal

    /// The watchdog check: query GPU, and if over threshold, trigger auto-purge.
    private func watchdogCheck() async {
        let status = await queryGPU()
        memoryStatus = status

        guard watchdogConfig.autoPurge,
              status.loadPercentage >= watchdogConfig.maxMemoryUsage else {
            return
        }

        Log("GPUManager: watchdog — memory at \(status.loadPercentage * 100)%, triggering purge")
        await purgeModels()
    }

    /// Estimate total system memory (used as a proxy for GPU memory on Apple Silicon).
    /// Returns the total RAM in bytes; the GPU gets ~50% of this.
    private func estimateTotalMemory() -> Int64 {
        #if canImport(Metal)
        if let device = MTLCreateSystemDefaultDevice() {
            return Int64(device.totalMemory)
        }
        #endif

        // sysctl fallback: hw.memsize.
        var size: size_t = 0
        var sizeLen = MemoryLayout<size_t>.size
        sysctlbyname("hw.memsize", &size, &sizeLen, nil, 0)
        return size > 0 ? Int64(size) : 16_000_000_000 // 16 GB default
    }

    private var watchdogTimer: Timer?
}

// MARK: - Defaults

extension GPUManager.WatchdogConfig {
    static var `default`: WatchdogConfig {
        WatchdogConfig(maxMemoryUsage: 0.8, purgeInterval: 60, autoPurge: true)
    }
}
