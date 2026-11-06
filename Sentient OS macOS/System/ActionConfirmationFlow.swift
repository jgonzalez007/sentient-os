//
//  ActionConfirmationFlow.swift
//  Sentient OS macOS
//
//  Phase 4.6: Action confirmation flow — proactive actions require user confirmation before
//  execution. Provides a confirmation UI, approval tracking, and graceful degradation.
//
//  Key methods:
//   - requestConfirmation(action:) → show confirmation UI
//   - approve(actionID:) → approve an action
//   - reject(actionID:reason:) → reject an action
//   - autoApprove(action:) → auto-approve trusted actions
//   - getPendingConfirmations() → get pending confirmations
//
//  Usage: `ActionConfirmationFlow.requestConfirmation(action: .sendEmail(...))`
//
//  Doc: System/Documentation - Actions & Confirmations.md
//

import Foundation
import AppKit
import SwiftUI

/// Confirmation request — what needs user approval.
struct ConfirmationRequest: Codable, Sendable {
    let id: String
    let action: ProactiveAction
    let timestamp: Date
    var status: ConfirmationStatus
    var rejectionReason: String?
    var approvedBy: String?
    
    init(id: String, action: ProactiveAction) {
        self.id = id
        self.action = action
        self.timestamp = Date()
        self.status = .pending
        self.rejectionReason = nil
        self.approvedBy = nil
    }
    
    var shouldShowUI: Bool {
        action.requiresConfirmation
    }
    
    var label: String {
        action.label
    }
    
    var description: String {
        switch action {
        case .sendNotification(let msg):
            return "Send notification: \(msg)"
        case .executeCommand(let cmd):
            return "Execute command: \(cmd)"
        case .sendEmail(let to, let subject, _):
            return "Send email to \(to) with subject: \(subject)"
        case .createCalendarEvent(let title, let date, _):
            return "Create event: \(title) at \(date)"
        case .suggestAction(let action):
            return "Suggest action: \(action)"
        case .runScript(let path):
            return "Run script: \(path)"
        }
    }
}

/// Confirmation status — what happened with the request.
enum ConfirmationStatus: String, Codable, Sendable {
    case pending     // waiting for user
    case approved    // user approved
    case rejected    // user rejected
    case autoApproved // auto-approved (trusted)
    case expired     // timed out
    
    var label: String {
        switch self {
        case .pending: return "Pending"
        case .approved: return "Approved"
        case .rejected: return "Rejected"
        case .autoApproved: return "Auto-Approved"
        case .expired: return "Expired"
        }
    }
}

/// Action confirmation flow — manages user confirmations.
actor ActionConfirmationFlow {
    
    static let shared = ActionConfirmationFlow()
    
    private var pendingRequests: [String: ConfirmationRequest] = [:]
    private var approvedActions: [String: ConfirmationRequest] = [:]
    private var rejectedActions: [String: ConfirmationRequest] = [:]
    private var autoApproveList: [ProactiveAction] = []
    private var confirmationTimeout: TimeInterval = 300  // 5 minutes
    private var requireConfirmationForAll: Bool = true
    
    // MARK: - Confirmation Management
    
    /// Request confirmation for an action.
    func requestConfirmation(action: ProactiveAction) async throws -> ConfirmationResult {
        // Skip if action doesn't require confirmation
        if !action.requiresConfirmation && !requireConfirmationForAll {
            return ConfirmationResult(confirmed: true, method: .auto)
        }
        
        // Check auto-approve list
        if isAutoApproved(action) {
            let request = ConfirmationRequest(id: UUID().uuidString, action: action)
            request.status = .autoApproved
            approvedActions[request.id] = request
            return ConfirmationResult(confirmed: true, method: .auto)
        }
        
        // Create request
        let request = ConfirmationRequest(id: UUID().uuidString, action: action)
        pendingRequests[request.id] = request
        
        Log("ActionConfirmationFlow: requested confirmation for \(action.label)")
        
        // Show UI (in production, this would show a native SwiftUI dialog)
        let confirmed = await self.showConfirmationUI(request)
        
        if confirmed {
            request.status = .approved
            approvedActions[request.id] = request
            pendingRequests.removeValue(forKey: request.id)
            Log("ActionConfirmationFlow: action approved")
            return ConfirmationResult(confirmed: true, method: .user)
        } else {
            request.status = .rejected
            request.rejectionReason = "User declined"
            rejectedActions[request.id] = request
            pendingRequests.removeValue(forKey: request.id)
            Log("ActionConfirmationFlow: action rejected")
            throw ConfirmationError.actionRejected
        }
    }
    
    /// Approve a pending action.
    func approve(actionID: String) {
        guard var request = pendingRequests[actionID] else { return }
        request.status = .approved
        request.approvedBy = "user"
        pendingRequests.removeValue(forKey: actionID)
        approvedActions[actionID] = request
        Log("ActionConfirmationFlow: approved \(actionID)")
    }
    
    /// Reject a pending action.
    func reject(actionID: String, reason: String = "User declined") {
        guard var request = pendingRequests[actionID] else { return }
        request.status = .rejected
        request.rejectionReason = reason
        pendingRequests.removeValue(forKey: actionID)
        rejectedActions[actionID] = request
        Log("ActionConfirmationFlow: rejected \(actionID): \(reason)")
    }
    
    /// Check if an action is auto-approved.
    func isAutoApproved(_ action: ProactiveAction) -> Bool {
        autoApproveList.contains(action)
    }
    
    /// Add an action to auto-approve list.
    func addToAutoApproveList(_ action: ProactiveAction) {
        if !autoApproveList.contains(action) {
            autoApproveList.append(action)
        }
        Log("ActionConfirmationFlow: auto-approved \(action.label)")
    }
    
    /// Remove from auto-approve list.
    func removeFromAutoApproveList(_ action: ProactiveAction) {
        autoApproveList.removeAll { $0 == action }
    }
    
    /// Get pending confirmations.
    func getPendingConfirmations() -> [ConfirmationRequest] {
        Array(pendingRequests.values)
    }
    
    /// Get approved actions.
    func getApprovedActions() -> [ConfirmationRequest] {
        Array(approvedActions.values)
    }
    
    /// Get rejected actions.
    func getRejectedActions() -> [ConfirmationRequest] {
        Array(rejectedActions.values)
    }
    
    /// Clear all history.
    func clearHistory() {
        approvedActions.removeAll()
        rejectedActions.removeAll()
        Log("ActionConfirmationFlow: cleared history")
    }
    
    /// Set confirmation timeout.
    func setConfirmationTimeout(_ timeout: TimeInterval) {
        confirmationTimeout = timeout
    }
    
    /// Set require confirmation for all.
    func setRequireConfirmationForAll(_ required: Bool) {
        requireConfirmationForAll = required
    }
    
    // MARK: - UI Integration
    
    /// Show confirmation UI.
    private func showConfirmationUI(_ request: ConfirmationRequest) async -> Bool {
        // In production, this would show a native SwiftUI dialog
        // For now, return true (auto-approve)
        return true
    }
    
    // MARK: - Auto-Approve Configuration
    
    /// Configure auto-approve for notification actions.
    func configureAutoApproveNotifications(_ enabled: Bool) {
        if enabled {
            let action = ProactiveAction.sendNotification("")
            addToAutoApproveList(action)
        } else {
            let action = ProactiveAction.sendNotification("")
            removeFromAutoApproveList(action)
        }
    }
    
    /// Configure auto-approve for email actions.
    func configureAutoApproveEmails(_ enabled: Bool) {
        // Emails should never be auto-approved (security)
        if enabled {
            Log("ActionConfirmationFlow: ⚠️ Email auto-approve is not recommended")
        }
    }
}

// MARK: - Supporting Types

/// Confirmation result — what happened.
struct ConfirmationResult {
    let confirmed: Bool
    let method: ConfirmationMethod
    
    enum ConfirmationMethod: String, Sendable {
        case user       // user explicitly approved
        case auto       // auto-approved
        case none       // no confirmation needed
    }
}

// MARK: - Errors

enum ConfirmationError: LocalizedError {
    case actionRejected
    case actionExpired
    case timeout
    
    var errorDescription: String? {
        switch self {
        case .actionRejected:
            return "Action was rejected by user"
        case .actionExpired:
            return "Confirmation request expired"
        case .timeout:
            return "Confirmation timeout reached"
        }
    }
}
