//
//  SessionReplay.swift
//  Sentient OS macOS
//
//  Phase 4.8: Session replay — record Sidekick's actions for audit/debug. Captures a
//  chronological log of all computer use actions, inputs, outputs, and system state.
//  Enables debugging, forensic analysis, and user review.
//
//  Key methods:
//   - recordEvent(event:) → record an event
//   - getReplay() → get full replay log
//   - exportReplay(format:) → export replay
//   - startRecording() → start recording
//   - stopRecording() → stop recording
//
//  Usage: `SessionReplay.recordEvent(.action(input: "...", output: "..."))`
//
//  Doc: Diagnostics/Documentation - Session Replay.md
//

import Foundation

/// Replay event — one action in a session.
struct ReplayEvent: Codable, Sendable {
    let id: String
    let timestamp: Date
    let eventType: EventType
    let eventData: EventData
    
    enum EventType: String, Codable, Sendable {
        case userInput
        case aiDecision
        case computerAction
        case systemState
        case error
        case milestone
    }
    
    struct EventData: Codable, Sendable {
        let details: [String: Any]
        
        init(details: [String: Any]) {
            self.details = details
        }
    }
    
    init(id: String = UUID().uuidString, timestamp: Date = Date(), eventType: EventType, eventData: EventData) {
        self.id = id
        self.timestamp = timestamp
        self.eventType = eventType
        self.eventData = eventData
    }
    
    static func userInput(_ text: String) -> ReplayEvent {
        ReplayEvent(eventType: .userInput, eventData: EventData(details: ["text": text]))
    }
    
    static func aiDecision(_ decision: String, reasoning: String? = nil) -> ReplayEvent {
        ReplayEvent(eventType: .aiDecision, eventData: EventData(details: [
            "decision": decision,
            "reasoning": reasoning ?? ""
        ]))
    }
    
    static func computerAction(_ action: String, success: Bool, output: String? = nil) -> ReplayEvent {
        ReplayEvent(eventType: .computerAction, eventData: EventData(details: [
            "action": action,
            "success": success,
            "output": output ?? ""
        ]))
    }
    
    static func systemState(_ state: String, details: [String: Any] = [:]) -> ReplayEvent {
        ReplayEvent(eventType: .systemState, eventData: EventData(details: [
            "state": state,
            "details": details
        ]))
    }
    
    static func error(_ error: String, recovery: String? = nil) -> ReplayEvent {
        ReplayEvent(eventType: .error, eventData: EventData(details: [
            "error": error,
            "recovery": recovery ?? ""
        ]))
    }
    
    static func milestone(_ milestone: String) -> ReplayEvent {
        ReplayEvent(eventType: .milestone, eventData: EventData(details: [
            "milestone": milestone
        ]))
    }
}

/// Session replay — a record of all events in a session.
struct SessionReplayData: Codable, Sendable {
    let sessionID: String
    let startTime: Date
    let events: [ReplayEvent]
    let endTime: Date?
    let duration: TimeInterval
    let eventCount: Int
    let errorCount: Int
    
    init(sessionID: String, startTime: Date) {
        self.sessionID = sessionID
        self.startTime = startTime
        self.events = []
        self.endTime = nil
        self.duration = 0
        self.eventCount = 0
        self.errorCount = 0
    }
    
    func addEvent(_ event: ReplayEvent) {
        var events = self.events
        events.append(event)
        
        let isError = event.eventType == .error
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        
        self = SessionReplayData(
            sessionID: sessionID,
            startTime: startTime,
            events: events,
            endTime: endTime,
            duration: duration,
            eventCount: events.count,
            errorCount: events.filter { $0.eventType == .error }.count
        )
    }
}

/// Session replay engine — records and replays Sidekick actions.
actor SessionReplay {
    
    static let shared = SessionReplay()
    
    private var activeReplays: [String: SessionReplayData] = [:]
    private var completedReplays: [SessionReplayData] = []
    private var isRecording: Bool = false
    
    // MARK: - Recording Control
    
    /// Start recording a session.
    func startRecording(sessionID: String) {
        activeReplays[sessionID] = SessionReplayData(sessionID: sessionID, startTime: Date())
        isRecording = true
        Log("SessionReplay: started recording session \(sessionID)")
    }
    
    /// Stop recording a session.
    func stopRecording(sessionID: String) {
        guard var replay = activeReplays[sessionID] else { return }
        replay.endTime = Date()
        replay.duration = replay.endTime!.timeIntervalSince(replay.startTime)
        replay.eventCount = replay.events.count
        replay.errorCount = replay.events.filter { $0.eventType == .error }.count
        
        completedReplays.append(replay)
        activeReplays.removeValue(forKey: sessionID)
        
        Log("SessionReplay: stopped recording session \(sessionID) — \(replay.eventCount) events, \(replay.errorCount) errors")
    }
    
    /// Record an event.
    func recordEvent(_ event: ReplayEvent, for sessionID: String) {
        guard var replay = activeReplays[sessionID] else { return }
        replay.addEvent(event)
        activeReplays[sessionID] = replay
    }
    
    /// Get a replay.
    func getReplay(sessionID: String) -> SessionReplayData? {
        activeReplays[sessionID] ?? completedReplays.last(where: { $0.sessionID == sessionID })
    }
    
    /// Get all replays.
    func getAllReplays() -> [SessionReplayData] {
        completedReplays
    }
    
    /// Export a replay.
    func exportReplay(sessionID: String, format: ExportFormat) -> String? {
        guard let replay = getReplay(sessionID: sessionID) else { return nil }
        
        switch format {
        case .json:
            return self.exportJSON(replay)
        case .text:
            return self.exportText(replay)
        case .markdown:
            return self.exportMarkdown(replay)
        }
    }
    
    /// Export as JSON.
    private func exportJSON(_ replay: SessionReplayData) -> String? {
        guard let data = try? JSONEncoder().encode(replay) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    /// Export as text.
    private func exportText(_ replay: SessionReplayData) -> String {
        var text = "Session Replay: \(replay.sessionID)\n"
        text += "Start: \(replay.startTime)\n"
        text += "End: \(replay.endTime?.description ?? "N/A")\n"
        text += "Duration: \(replay.duration)s\n"
        text += "Events: \(replay.eventCount)\n"
        text += "Errors: \(replay.errorCount)\n\n"
        
        for event in replay.events {
            text += "[\(event.timestamp)] (\(event.eventType.rawValue)) \(event.eventData.details)\n"
        }
        
        return text
    }
    
    /// Export as Markdown.
    private func exportMarkdown(_ replay: SessionReplayData) -> String {
        var md = "# Session Replay: \(replay.sessionID)\n\n"
        md += "| Field | Value |\n|-------|-------|\n"
        md += "| Start | \(replay.startTime) |\n"
        md += "| End | \(replay.endTime?.description ?? "N/A") |\n"
        md += "| Duration | \(replay.duration)s |\n"
        md += "| Events | \(replay.eventCount) |\n"
        md += "| Errors | \(replay.errorCount) |\n\n"
        md += "## Events\n\n"
        
        for event in replay.events {
            md += "- **[\(event.timestamp)]** \(event.eventType.rawValue): \(event.eventData.details)\n"
        }
        
        return md
    }
    
    // MARK: - Cleanup
    
    /// Clear completed replays.
    func clearCompleted() {
        completedReplays.removeAll()
        Log("SessionReplay: cleared completed replays")
    }
    
    /// Clear a replay.
    func clearReplay(sessionID: String) {
        completedReplays.removeAll { $0.sessionID == sessionID }
        Log("SessionReplay: cleared replay \(sessionID)")
    }
    
    /// Get replay count.
    var replayCount: Int {
        completedReplays.count
    }
    
    /// Get error count across all replays.
    var totalErrorCount: Int {
        completedReplays.reduce(0) { $0 + $1.errorCount }
    }
}

// MARK: - Supporting Types

/// Export format — how to export a replay.
enum ExportFormat: String, Codable, Sendable {
    case json
    case text
    case markdown
}
