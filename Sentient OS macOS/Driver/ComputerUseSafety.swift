//
//  ComputerUseSafety.swift
//  Sentient OS macOS
//
//  Phase 4.7: Computer use safety — kill switches, rate limiting, and user-visible progress.
//  Ensures Sidekick operations are safe, auditable, and interruptible.
//
//  Key methods:
//   - enableKillSwitch() → activate kill switch
//   - disableKillSwitch() → deactivate kill switch
//   - setRateLimit(requestsPerMinute:) → set rate limit
//   - trackProgress(taskID:progress:) → track task progress
//   - getProgress(taskID:) → get task progress
//   - interruptTask(taskID:) → interrupt a running task
//
//  Usage: `ComputerUseSafety.enableKillSwitch()` to immediately stop all operations.
//
//  Doc: Diagnostics/Documentation - Computer Use Safety.md
//

import Foundation

/// Kill switch status — whether operations are suspended.
enum KillSwitchStatus: String, Codable, Sendable {
    case off       // operations allowed
    case on        // operations suspended
    case temporary // temporary suspension
    
    var label: String {
        switch self {
        case .off: return "Off"
        case .on: return "On"
        case .temporary: return "Temporary"
        }
    }
}

/// Safety configuration — safety settings.
struct SafetyConfig: Codable, Sendable {
    var killSwitchStatus: KillSwitchStatus
    var rateLimitPerMinute: Int
    var rateLimitPerHour: Int
    var requireConfirmation: Bool
    var enableAuditLog: Bool
    var maxConcurrentTasks: Int
    var progressReportingInterval: TimeInterval  // seconds between progress updates
    
    init() {
        self.killSwitchStatus = .off
        self.rateLimitPerMinute = 60
        self.rateLimitPerHour = 1000
        self.requireConfirmation = true
        self.enableAuditLog = true
        self.maxConcurrentTasks = 3
        self.progressReportingInterval = 5.0
    }
    
    static let defaultConfig = SafetyConfig()
    static let strictConfig = SafetyConfig(
        killSwitchStatus: .off,
        rateLimitPerMinute = 10,
        rateLimitPerHour = 100,
        requireConfirmation: true,
        enableAuditLog: true,
        maxConcurrentTasks: 1,
        progressReportingInterval: 2.0
    )
}

/// Progress update — what's happening with a task.
struct ProgressUpdate: Codable, Sendable {
    let taskID: String
    let progress: Float       // 0.0 to 1.0
    let status: String
    let message: String?
    let timestamp: Date
    
    init(taskID: String, progress: Float, status: String, message: String? = nil) {
        self.taskID = taskID
        self.progress = progress
        self.status = status
        self.message = message
        self.timestamp = Date()
    }
}

/// Computer use safety — manages kill switches, rate limits, and progress tracking.
actor ComputerUseSafety {
    
    static let shared = ComputerUseSafety()
    
    private var config: SafetyConfig = .defaultConfig
    private var killSwitchActive: Bool = false
    private var rateLimits: [String: RateLimitInfo] = [:]
    private var progressUpdates: [String: [ProgressUpdate]] = [:]
    private var activeTasks: [String: TaskInfo] = [:]
    private var auditLog: [AuditEntry] = []
    
    // MARK: - Kill Switch
    
    /// Enable kill switch.
    func enableKillSwitch() {
        killSwitchActive = true
        config.killSwitchStatus = .on
        Log("ComputerUseSafety: KILL SWITCH ACTIVATED")
        
        // Interrupt all active tasks
        for (taskID, task) in activeTasks {
            task.isInterrupted = true
            activeTasks[taskID] = task
            Log("ComputerUseSafety: interrupted task \(taskID)")
        }
    }
    
    /// Disable kill switch.
    func disableKillSwitch() {
        killSwitchActive = false
        config.killSwitchStatus = .off
        Log("ComputerUseSafety: KILL SWITCH DEACTIVATED")
    }
    
    /// Check if kill switch is active.
    var isKillSwitchActive: Bool {
        killSwitchActive
    }
    
    /// Set kill switch status.
    func setKillSwitchStatus(_ status: KillSwitchStatus) {
        switch status {
        case .off:
            disableKillSwitch()
        case .on:
            enableKillSwitch()
        case .temporary:
            killSwitchActive = true
            config.killSwitchStatus = .temporary
            Log("ComputerUseSafety: temporary kill switch enabled")
        }
    }
    
    // MARK: - Rate Limiting
    
    /// Set rate limit.
    func setRateLimit(requestsPerMinute: Int, requestsPerHour: Int) {
        config.rateLimitPerMinute = requestsPerMinute
        config.rateLimitPerHour = requestsPerHour
        Log("ComputerUseSafety: rate limit set to \(requestsPerMinute)/min, \(requestsPerHour)/hr")
    }
    
    /// Check rate limit for a task.
    func checkRateLimit(taskID: String) throws {
        let now = Date()
        let oneMinuteAgo = now.addingTimeInterval(-60)
        let oneHourAgo = now.addingTimeInterval(-3600)
        
        var rateInfo = rateLimits[taskID] ?? RateLimitInfo(count: 0, lastReset: now)
        
        // Reset counts if needed
        if now.timeIntervalSince(rateInfo.lastReset) > 3600 {
            rateInfo.count = 0
            rateInfo.lastReset = now
        }
        
        rateInfo.count += 1
        rateLimits[taskID] = rateInfo
        
        if rateInfo.count > config.rateLimitPerMinute {
            throw SafetyError.rateLimitExceeded(taskID, "minute")
        }
        
        // Also check hourly
        let hourlyCount = rateInfo.count * Int(now.timeIntervalSince(rateInfo.lastReset) / 60)
        if hourlyCount > config.rateLimitPerHour {
            throw SafetyError.rateLimitExceeded(taskID, "hour")
        }
    }
    
    // MARK: - Progress Tracking
    
    /// Track task progress.
    func trackProgress(taskID: String, progress: Float, status: String, message: String? = nil) {
        let update = ProgressUpdate(taskID: taskID, progress: progress, status: status, message: message)
        
        if progressUpdates[taskID] == nil {
            progressUpdates[taskID] = []
        }
        progressUpdates[taskID]!.append(update)
        
        Log("ComputerUseSafety: task \(taskID) progress \(progress) — \(status)")
    }
    
    /// Get progress for a task.
    func getProgress(taskID: String) -> [ProgressUpdate] {
        progressUpdates[taskID] ?? []
    }
    
    /// Get latest progress for a task.
    func getLatestProgress(taskID: String) -> ProgressUpdate? {
        progressUpdates[taskID]?.last
    }
    
    // MARK: - Task Management
    
    /// Start a task.
    func startTask(taskID: String, maxSteps: Int) throws {
        guard !killSwitchActive else {
            throw SafetyError.killSwitchActive
        }
        
        let activeCount = activeTasks.filter { !$0.value.isInterrupted }.count
        guard activeCount < config.maxConcurrentTasks else {
            throw SafetyError.tooManyTasks(config.maxConcurrentTasks)
        }
        
        activeTasks[taskID] = TaskInfo(taskID: taskID, maxSteps: maxSteps, isInterrupted: false)
        Log("ComputerUseSafety: started task \(taskID)")
    }
    
    /// Interrupt a task.
    func interruptTask(taskID: String) {
        guard var task = activeTasks[taskID] else { return }
        task.isInterrupted = true
        activeTasks[taskID] = task
        Log("ComputerUseSafety: interrupted task \(taskID)")
    }
    
    /// Complete a task.
    func completeTask(taskID: String) {
        activeTasks.removeValue(forKey: taskID)
        Log("ComputerUseSafety: completed task \(taskID)")
    }
    
    /// Get active task count.
    var activeTaskCount: Int {
        activeTasks.filter { !$1.value.isInterrupted }.count
    }
    
    // MARK: - Audit Logging
    
    /// Log an audit entry.
    func logAudit(action: String, details: String? = nil, success: Bool = true) {
        guard config.enableAuditLog else { return }
        
        let entry = AuditEntry(
            action: action,
            details: details,
            timestamp: Date(),
            success: success,
            killSwitchActive: killSwitchActive
        )
        auditLog.append(entry)
        
        // Keep only last 1000 entries
        if auditLog.count > 1000 {
            auditLog = Array(auditLog.suffix(1000))
        }
    }
    
    /// Get audit log.
    func getAuditLog(limit: Int = 100) -> [AuditEntry] {
        Array(auditLog.suffix(limit))
    }
    
    /// Clear audit log.
    func clearAuditLog() {
        auditLog.removeAll()
        Log("ComputerUseSafety: audit log cleared")
    }
    
    // MARK: - Configuration
    
    /// Get safety config.
    var safetyConfig: SafetyConfig {
        config
    }
    
    /// Set safety config.
    func setSafetyConfig(_ config: SafetyConfig) {
        self.config = config
        Log("ComputerUseSafety: config updated")
    }
}

// MARK: - Supporting Types

/// Rate limit info — tracking for a task.
struct RateLimitInfo: Codable {
    var count: Int
    var lastReset: Date
}

/// Task info — tracking for a task.
struct TaskInfo: Codable {
    let taskID: String
    let maxSteps: Int
    var isInterrupted: Bool
}

/// Audit entry — for audit/debug.
struct AuditEntry: Codable {
    let action: String
    let details: String?
    let timestamp: Date
    let success: Bool
    let killSwitchActive: Bool
}

// MARK: - Errors

enum SafetyError: LocalizedError {
    case killSwitchActive
    case rateLimitExceeded(String, String)  // taskID, period
    case tooManyTasks(Int)
    case taskNotFound(String)
    case invalidProgress
    
    var errorDescription: String? {
        switch self {
        case .killSwitchActive:
            return "Kill switch is active — all operations suspended"
        case .rateLimitExceeded(let taskID, let period):
            return "Rate limit exceeded for task \(taskID) — \(period) quota reached"
        case .tooManyTasks(let max):
            return "Too many tasks active — max \(max)"
        case .taskNotFound(let taskID):
            return "Task not found: \(taskID)"
        case .invalidProgress:
            return "Invalid progress value"
        }
    }
}
