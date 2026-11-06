//
//  ComputerUseSandbox.swift
//  Sentient OS macOS
//
//  Phase 4.1: Computer use sandbox — Sidekick runs in a sandboxed environment with
//  permission boundaries. Enforces least-privilege access, rate limiting, and kill switches.
//
//  Key methods:
//   - createSession(id:permissions:) → create a sandboxed session
//   - executeAction(session:action:) → execute an action within sandbox
//   - revokeAccess(session:)        → revoke session permissions
//   - killSwitch()                  → kill all active sessions
//   - checkRateLimit()              → enforce rate limiting
//
//  Usage: `ComputerUseSandbox.createSession(id: "session-1", permissions: [.read])`
//
//  Doc: Driver/Documentation - Driver (cua-driver).md
//

import Foundation
import AppKit

/// Permission level — what a session can do.
enum SessionPermission: String, Codable, Sendable {
    case read              // read only (files, calendar, etc.)
    case write             // read + write
    case execute           // execute actions
    case system            // system-level access
    case network           // network access
    case clipboard         // clipboard access
    case keyboard          // keyboard input
    case mouse             // mouse control
    case screen            // screen capture
    
    var label: String {
        switch self {
        case .read: return "Read Only"
        case .write: return "Read & Write"
        case .execute: return "Execute"
        case .system: return "System"
        case .network: return "Network"
        case .clipboard: return "Clipboard"
        case .keyboard: return "Keyboard"
        case .mouse: return "Mouse"
        case .screen: return "Screen"
        }
    }
}

/// Sandbox policy — rules for what's allowed.
struct SandboxPolicy: Codable, Sendable {
    var maxActionsPerMinute: Int = 60
    var maxActionsPerHour: Int = 1000
    var allowScreenCapture: Bool = true
    var allowKeyboardControl: Bool = true
    var allowMouseControl: Bool = true
    var allowNetworkAccess: Bool = false
    var allowFileAccess: Bool = true
    var allowedPaths: [String] = []  // empty = all paths
    var requireConfirmation: Bool = true
    var timeoutSeconds: Int = 300
    
    init() {}
    
    static let defaultPolicy = SandboxPolicy()
    static let strictPolicy = SandboxPolicy(
        maxActionsPerMinute: 10,
        maxActionsPerHour: 100,
        allowScreenCapture: false,
        allowKeyboardControl: false,
        allowMouseControl: false,
        allowNetworkAccess: false,
        allowFileAccess: true,
        requireConfirmation: true,
        timeoutSeconds: 60
    )
}

/// A computer use session — represents a sandboxed AI operation.
struct ComputerUseSession: Codable, Sendable {
    let id: String
    let permissions: Set<SessionPermission>
    let policy: SandboxPolicy
    let createdAt: Date
    let lastActionAt: Date
    var actionCount: Int
    var isActive: Bool
    var isKilled: Bool
    
    init(id: String, permissions: Set<SessionPermission>, policy: SandboxPolicy) {
        self.id = id
        self.permissions = permissions
        self.policy = policy
        self.createdAt = Date()
        self.lastActionAt = Date()
        self.actionCount = 0
        self.isActive = true
        self.isKilled = false
    }
}

/// Computer use sandbox — manages sandboxed sessions with permission boundaries.
actor ComputerUseSandbox {
    
    static let shared = ComputerUseSandbox()
    
    private var sessions: [String: ComputerUseSession] = [:]
    private var actionLog: [ActionEntry] = []
    private var killSwitchActive: Bool = false
    
    // MARK: - Session Management
    
    /// Create a new sandboxed session.
    func createSession(id: String, permissions: Set<SessionPermission>, policy: SandboxPolicy? = nil) throws {
        guard !killSwitchActive else {
            throw SandboxError.killSwitchActive
        }
        
        let session = ComputerUseSession(
            id: id,
            permissions: permissions,
            policy: policy ?? .defaultPolicy
        )
        
        sessions[id] = session
        Log("ComputerUseSandbox: session \(id) created with \(permissions.count) permissions")
    }
    
    /// Execute an action within a sandboxed session.
    func executeAction(sessionID: String, action: ComputerAction) async throws {
        guard let session = sessions[sessionID] else {
            throw SandboxError.sessionNotFound(sessionID)
        }
        
        guard session.isActive && !session.isKilled else {
            throw SandboxError.sessionInactive(sessionID)
        }
        
        // Check kill switch
        guard !killSwitchActive else {
            throw SandboxError.killSwitchActive
        }
        
        // Check rate limits
        try checkRateLimit(for: sessionID)
        
        // Check permissions
        guard session.permissions.contains(action.requiredPermission) else {
            throw SandboxError.permissionDenied(sessionID, action.requiredPermission)
        }
        
        // Execute the action
        try await action.execute()
        
        // Update session
        session.actionCount += 1
        session.lastActionAt = Date()
        sessions[sessionID] = session
        
        // Log the action
        actionLog.append(ActionEntry(
            sessionID: sessionID,
            action: action,
            timestamp: Date(),
            success: true
        ))
    }
    
    /// Revoke access for a session.
    func revokeAccess(sessionID: String) throws {
        guard let session = sessions[sessionID] else {
            throw SandboxError.sessionNotFound(sessionID)
        }
        
        session.isActive = false
        sessions[sessionID] = session
        Log("ComputerUseSandbox: session \(sessionID) access revoked")
    }
    
    /// Activate kill switch — terminates all active sessions.
    func activateKillSwitch() {
        killSwitchActive = true
        for (id, session) in sessions {
            if session.isActive {
                sessions[id]?.isActive = false
                Log("ComputerUseSandbox: killed session \(id)")
            }
        }
        Log("ComputerUseSandbox: kill switch ACTIVATED — all sessions terminated")
    }
    
    /// Deactivate kill switch.
    func deactivateKillSwitch() {
        killSwitchActive = false
        Log("ComputerUseSandbox: kill switch DEACTIVATED")
    }
    
    /// Check rate limit for a session.
    private func checkRateLimit(for sessionID: String) throws {
        guard let session = sessions[sessionID] else { throw SandboxError.sessionNotFound(sessionID) }
        
        let now = Date()
        let oneMinuteAgo = now.addingTimeInterval(-60)
        let oneHourAgo = now.addingTimeInterval(-3600)
        
        // Count recent actions
        let actionsThisMinute = actionLog.filter {
            $0.sessionID == sessionID && $0.timestamp >= oneMinuteAgo
        }.count
        
        let actionsThisHour = actionLog.filter {
            $0.sessionID == sessionID && $0.timestamp >= oneHourAgo
        }.count
        
        if actionsThisMinute >= session.policy.maxActionsPerMinute {
            throw SandboxError.rateLimitExceeded(sessionID, "minute")
        }
        
        if actionsThisHour >= session.policy.maxActionsPerHour {
            throw SandboxError.rateLimitExceeded(sessionID, "hour")
        }
    }
    
    // MARK: - Session Status
    
    /// Get session status.
    func getSessionStatus(sessionID: String) -> SessionStatus? {
        guard let session = sessions[sessionID] else { return nil }
        
        let actionsThisMinute = actionLog.filter {
            $0.sessionID == sessionID && $0.timestamp >= Date().addingTimeInterval(-60)
        }.count
        
        let actionsThisHour = actionLog.filter {
            $0.sessionID == sessionID && $0.timestamp >= Date().addingTimeInterval(-3600)
        }.count
        
        return SessionStatus(
            sessionID: sessionID,
            isActive: session.isActive,
            isKilled: session.isKilled,
            actionCount: session.actionCount,
            actionsThisMinute: actionsThisMinute,
            actionsThisHour: actionsThisHour,
            permissions: session.permissions
        )
    }
    
    /// Get all active sessions.
    func getActiveSessions() -> [ComputerUseSession] {
        Array(sessions.values.filter { $0.isActive && !$0.isKilled })
    }
    
    // MARK: - Cleanup
    
    /// Cleanup expired sessions.
    func cleanupExpiredSessions() {
        let now = Date()
        for (id, session) in sessions {
            if !session.isActive && now.timeIntervalSince(session.lastActionAt) > 3600 {
                sessions.removeValue(forKey: id)
                Log("ComputerUseSandbox: cleaned up expired session \(id)")
            }
        }
    }
    
    // MARK: - Audit Log
    
    /// Get audit log entries.
    func getAuditLog(limit: Int = 100) -> [ActionEntry] {
        Array(actionLog.suffix(limit))
    }
    
    /// Clear audit log.
    func clearAuditLog() {
        actionLog.removeAll()
        Log("ComputerUseSandbox: audit log cleared")
    }
}

// MARK: - Supporting Types

/// A computer use action — what Sidekick can do.
protocol ComputerAction: Sendable {
    var requiredPermission: SessionPermission { get }
    func execute() async throws
}

/// Session status — current state of a session.
struct SessionStatus: Sendable {
    let sessionID: String
    let isActive: Bool
    let isKilled: Bool
    let actionCount: Int
    let actionsThisMinute: Int
    let actionsThisHour: Int
    let permissions: Set<SessionPermission>
}

/// Action log entry — for audit/debug.
struct ActionEntry: Codable, Sendable {
    let sessionID: String
    let action: ComputerAction  // This won't work directly — need a serializable representation
    let timestamp: Date
    let success: Bool
    
    init(sessionID: String, actionType: String, timestamp: Date, success: Bool) {
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.success = success
        // Note: action needs to be a simple type for serialization
    }
}

// MARK: - Errors

enum SandboxError: LocalizedError {
    case killSwitchActive
    case sessionNotFound(String)
    case sessionInactive(String)
    case permissionDenied(String, SessionPermission)
    case rateLimitExceeded(String, String)  // sessionID, period
    case invalidAction
    
    var errorDescription: String? {
        switch self {
        case .killSwitchActive:
            return "Kill switch is active — all computer use actions are suspended"
        case .sessionNotFound(let id):
            return "Session not found: \(id)"
        case .sessionInactive(let id):
            return "Session \(id) is inactive"
        case .permissionDenied(let id, let perm):
            return "Session \(id) lacks \(perm.label) permission"
        case .rateLimitExceeded(let id, let period):
            return "Rate limit exceeded for session \(id) — \(period) quota reached"
        case .invalidAction:
            return "Invalid action"
        }
    }
}

// MARK: - Extension for ComputerAction protocol

extension ComputerAction {
    func execute() async throws {
        throw SandboxError.invalidAction
    }
}
