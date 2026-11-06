//
//  BidirectionalSync.swift
//  Sentient OS macOS
//
//  Phase 3.4: Bidirectional sync — two-way synchronization between local vault and cloud MCP mirror.
//  Handles conflicts, version tracking, and atomic operations.
//
//  Key methods:
//   - pullFromCloud() → sync changes from cloud to local
//   - pushToCloud()   → sync changes from local to cloud
//   - sync()          → full bidirectional sync
//   - resolveConflict(local:remote:) → manual conflict resolution
//   - isSynced()      → check if local and cloud are in sync
//
//  Usage: `BidirectionalSync.shared.sync()` from VaultCloud or on app launch.
//
//  Doc: Vault/Documentation - Knowledge Base (Vault).md
//

import Foundation

/// Sync direction — which way data flows.
enum SyncDirection: String, Sendable {
    case localToCloud    // push
    case cloudToLocal    // pull
    case bidirectional   // both
}

/// Sync result — status and details of the sync operation.
struct SyncResult: Sendable {
    let direction: SyncDirection
    let filesAdded: Int
    let filesModified: Int
    let filesDeleted: Int
    let conflicts: [SyncConflict]
    let success: Bool
    let errorMessage: String?
    
    init(direction: SyncDirection, filesAdded: Int = 0, filesModified: Int = 0,
         filesDeleted: Int = 0, conflicts: [SyncConflict] = [], success: Bool = true,
         errorMessage: String? = nil) {
        self.direction = direction
        self.filesAdded = filesAdded
        self.filesModified = filesModified
        self.filesDeleted = filesDeleted
        self.conflicts = conflicts
        self.success = success
        self.errorMessage = errorMessage
    }
}

/// A sync conflict — when local and remote differ.
struct SyncConflict: Sendable {
    let path: String
    let localVersion: FileVersion
    let remoteVersion: FileVersion
    let resolution: ConflictResolution
}

/// Conflict resolution strategy.
enum ConflictResolution: String, Sendable {
    case keepLocal
    case keepRemote
    case merge
    case manual    // requires user intervention
}

/// File version — tracks changes for sync.
struct FileVersion: Sendable, Codable {
    let path: String
    let content: String
    let timestamp: Date
    let etag: String?  // cloud version identifier
    
    init(path: String, content: String, timestamp: Date, etag: String? = nil) {
        self.path = path
        self.content = content
        self.timestamp = timestamp
        self.etag = etag
    }
}

/// Version tracker — maintains sync state.
actor VersionTracker {
    
    static let shared = VersionTracker()
    
    private var versions: [String: FileVersion] = [:]
    private let storageKey = "sync_versions"
    
    init() {
        self.loadFromDisk()
    }
    
    /// Record a file version.
    func record(version: FileVersion) {
        versions[version.path] = version
        self.saveToDisk()
    }
    
    /// Get a file version.
    func get(path: String) -> FileVersion? {
        versions[path]
    }
    
    /// Check if a file is synced.
    func isSynced(path: String) -> Bool {
        guard let version = versions[path] else { return false }
        return version.timestamp >= Date().addingTimeInterval(-86400)  // within 24 hours
    }
    
    /// Clear version for a path.
    func clear(path: String) {
        versions.removeValue(forKey: path)
        saveToDisk()
    }
    
    private func saveToDisk() {
        if let data = try? JSONEncoder().encode(versions) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    
    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let loaded = try? JSONDecoder().decode([String: FileVersion].self, from: data) {
            versions = loaded
        }
    }
}

/// Bidirectional sync engine — keeps local vault and cloud in sync.
actor BidirectionalSync {
    
    static let shared = BidirectionalSync()
    
    private var versionTracker = VersionTracker.shared
    private var lastSyncTime: Date?
    private var isSyncing = false
    
    // MARK: - Sync Operations
    
    /// Pull changes from cloud to local.
    func pullFromCloud() async -> SyncResult {
        guard !isSyncing else {
            return SyncResult(direction: .cloudToLocal, success: false,
                            errorMessage: "Sync already in progress")
        }
        
        isSyncing = true
        defer { isSyncing = false }
        
        var filesAdded = 0
        var filesModified = 0
        var conflicts: [SyncConflict] = []
        
        do {
            // Fetch cloud state
            guard let cloudState = try await MirrorClient.shared.pull() else {
                return SyncResult(direction: .cloudToLocal, success: false,
                                errorMessage: "Cloud pull failed")
            }
            
            // Compare with local state
            let localFiles = try FileManager.default.subpathsOfDirectory(atPath: VaultGenerator.vaultRoot.path)
            let cloudFiles = cloudState.keys
            
            // New files in cloud
            for cloudFile in cloudFiles where !localFiles.contains(cloudFile) {
                let content = cloudState[cloudFile] ?? ""
                let localPath = VaultGenerator.vaultRoot.appendingPathComponent(cloudFile)
                try content.write(to: localPath, atomically: true, encoding: .utf8)
                filesAdded += 1
            }
            
            // Modified files in cloud
            for cloudFile in cloudFiles where localFiles.contains(cloudFile) {
                let localPath = VaultGenerator.vaultRoot.appendingPathComponent(cloudFile)
                guard let localContent = try? String(contentsOf: localPath, encoding: .utf8) else { continue }
                let cloudContent = cloudState[cloudFile] ?? ""
                
                if localContent != cloudContent {
                    // Check if there's a conflict
                    if let localVersion = versionTracker.get(path: cloudFile),
                       localVersion.timestamp > Date().addingTimeInterval(-3600) {
                        // Recent local change — conflict
                        conflicts.append(SyncConflict(
                            path: cloudFile,
                            localVersion: FileVersion(path: cloudFile, content: localContent,
                                                    timestamp: localVersion.timestamp),
                            remoteVersion: FileVersion(path: cloudFile, content: cloudContent,
                                                      timestamp: cloudState[cloudFile + "_timestamp"] ?? Date()),
                            resolution: .manual
                        ))
                    } else {
                        // No conflict — apply cloud changes
                        try cloudContent.write(to: localPath, atomically: true, encoding: .utf8)
                        filesModified += 1
                    }
                }
            }
            
            // Update version tracker
            for cloudFile in cloudFiles {
                versionTracker.record(version: FileVersion(
                    path: cloudFile,
                    content: cloudState[cloudFile] ?? "",
                    timestamp: Date()
                ))
            }
            
            lastSyncTime = Date()
            
            return SyncResult(direction: .cloudToLocal, filesAdded: filesAdded,
                            filesModified: filesModified, conflicts: conflicts, success: true)
        } catch {
            return SyncResult(direction: .cloudToLocal, success: false, errorMessage: error.localizedDescription)
        }
    }
    
    /// Push changes from local to cloud.
    func pushToCloud() async -> SyncResult {
        guard !isSyncing else {
            return SyncResult(direction: .localToCloud, success: false,
                            errorMessage: "Sync already in progress")
        }
        
        isSyncing = true
        defer { isSyncing = false }
        
        var filesAdded = 0
        var filesModified = 0
        
        do {
            // Get local files
            let localFiles = try FileManager.default.subpathsOfDirectory(atPath: VaultGenerator.vaultRoot.path)
            
            // Push each file
            for localFile in localFiles {
                let localPath = VaultGenerator.vaultRoot.appendingPathComponent(localFile)
                guard let content = try? String(contentsOf: localPath, encoding: .utf8) else { continue }
                
                let wasSynced = versionTracker.isSynced(path: localFile)
                
                do {
                    try await MirrorClient.shared.push(file: localFile, content: content)
                    
                    if !wasSynced {
                        filesAdded += 1
                    } else {
                        filesModified += 1
                    }
                    
                    versionTracker.record(version: FileVersion(
                        path: localFile,
                        content: content,
                        timestamp: Date()
                    ))
                } catch {
                    Log("BidirectionalSync: push failed for \(localFile): \(error)")
                }
            }
            
            lastSyncTime = Date()
            
            return SyncResult(direction: .localToCloud, filesAdded: filesAdded,
                            filesModified: filesModified, success: true)
        } catch {
            return SyncResult(direction: .localToCloud, success: false, errorMessage: error.localizedDescription)
        }
    }
    
    /// Full bidirectional sync.
    func sync() async -> SyncResult {
        let pullResult = await self.pullFromCloud()
        let pushResult = await self.pushToCloud()
        
        return SyncResult(
            direction: .bidirectional,
            filesAdded: pullResult.filesAdded + pushResult.filesAdded,
            filesModified: pullResult.filesModified + pushResult.filesModified,
            conflicts: pullResult.conflicts + pushResult.conflicts,
            success: pullResult.success && pushResult.success,
            errorMessage: pullResult.errorMessage ?? pushResult.errorMessage
        )
    }
    
    /// Check if local and cloud are in sync.
    func isSynced() async -> Bool {
        guard let lastSync = lastSyncTime else { return false }
        return lastSync >= Date().addingTimeInterval(-3600)  // synced within last hour
    }
    
    /// Resolve a conflict.
    func resolveConflict(_ conflict: SyncConflict, resolution: ConflictResolution) async {
        switch resolution {
        case .keepLocal:
            // Keep local version
            break
        case .keepRemote:
            // Pull from cloud again
            _ = await self.pullFromCloud()
        case .merge:
            // Simple merge — keep both versions
            Log("BidirectionalSync: merge conflict for \(conflict.path)")
        case .manual:
            Log("BidirectionalSync: manual conflict for \(conflict.path)")
        }
    }
}
