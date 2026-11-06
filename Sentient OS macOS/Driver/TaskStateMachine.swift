//
//  TaskStateMachine.swift
//  Sentient OS macOS
//
//  Phase 4.3: Task state machine — persist/restore Sidekick task state across app restarts.
//  Uses a finite state machine (FSM) with durable persistence, snapshot/restore, and
//  recovery from crashes or interruptions.
//
//  Key methods:
//   - createTask(id:) → create a new task
//   - transition(task:to:) → transition to a new state
//   - persist(task:) → save state to disk
//   - restore(task:) → restore state from disk
//   - getState(task:) → get current state
//
//  Usage: `TaskStateMachine.createTask(id: "task-1")` then `TaskStateMachine.transition(task: "task-1", to: .running)`
//
//  Doc: Notch Magic/Documentation - Sidekick.md
//

import Foundation

/// Sidekick task state — what a task is doing.
enum TaskState: String, Codable, Sendable, CaseIterable {
    case idle           // waiting for input
    case analyzing      // analyzing user request
    case planning       // planning steps
    case executing      // executing steps
    case paused         // paused (waiting for user)
    case completed      // completed successfully
    case failed         // failed
    case retrying       // retrying after failure
    
    var label: String {
        switch self {
        case .idle: return "Idle"
        case .analyzing: return "Analyzing"
        case .planning: return "Planning"
        case .executing: return "Executing"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .retrying: return "Retrying"
        }
    }
}

/// State transition — valid transitions between states.
struct StateTransition: Codable, Sendable {
    let from: TaskState
    let to: TaskState
    let isValid: Bool
    let condition: String?
    
    static let transitions: [[TaskState: [TaskState]]] = [
        [.idle: [.analyzing, .completed, .failed]],
        [.analyzing: [.planning, .failed, .idle]],
        [.planning: [.executing, .failed, .planning, .idle]],
        [.executing: [.paused, .completed, .failed, .retrying, .executing]],
        [.paused: [.executing, .completed, .failed, .idle]],
        [.completed: [.idle]],
        [.failed: [.retrying, .idle, .completed]],
        [.retrying: [.executing, .failed, .idle]]
    ]
    
    init(from: TaskState, to: TaskState) {
        self.from = from
        self.to = to
        self.isValid = Self.isValidTransition(from, to)
        self.condition = Self.transitionCondition(from, to)
    }
    
    static func isValidTransition(_ from: TaskState, _ to: TaskState) -> Bool {
        guard let validTransitions = transitions.first(where: { $0.key == from }) else {
            return false
        }
        return validTransitions[value: to] != nil
    }
    
    static func transitionCondition(_ from: TaskState, _ to: TaskState) -> String? {
        switch (from, to) {
        case (.idle, .analyzing): return "User sent a request"
        case (.analyzing, .planning): return "Analysis complete"
        case (.planning, .executing): return "Plan ready"
        case (.executing, .paused): return "User paused"
        case (.paused, .executing): return "User resumed"
        case (.executing, .completed): return "All steps done"
        case (.executing, .failed): return "Step failed"
        case (.failed, .retrying): return "Retrying"
        case (.retrying, .executing): return "Retry ready"
        default: return nil
        }
    }
}

/// A task — represents a Sidekick operation with state tracking.
struct TaskRecord: Codable, Sendable {
    let id: String
    var state: TaskState
    let task: String
    var currentStateAt: Date
    var transitions: [TransitionRecord]
    let createdAt: Date
    var updatedAt: Date
    var metadata: [String: Any]
    
    struct TransitionRecord: Codable, Sendable {
        let from: TaskState
        let to: TaskState
        let timestamp: Date
        let reason: String
    }
    
    init(id: String, task: String, initialState: TaskState = .idle) {
        self.id = id
        self.state = initialState
        self.task = task
        self.currentStateAt = Date()
        self.transitions = []
        self.createdAt = Date()
        self.updatedAt = Date()
        self.metadata = [:]
    }
    
    func transition(to newState: TaskState, reason: String = "") {
        let transition = StateTransition(from: state, to: newState)
        guard transition.isValid else {
            Log("TaskStateMachine: invalid transition \(state.rawValue) → \(newState.rawValue)")
            return
        }
        
        let record = TransitionRecord(from: state, to: newState, timestamp: Date(), reason: reason)
        transitions.append(record)
        state = newState
        currentStateAt = Date()
        updatedAt = Date()
        
        Log("TaskStateMachine: \(id) \(state.rawValue) → \(newState.rawValue) (\(reason))")
    }
    
    func snapshot() -> String {
        return """
        Task: \(task)
        State: \(state.rawValue)
        Created: \(createdAt)
        Updated: \(updatedAt)
        Transitions: \(transitions.count)
        """
    }
}

/// Task state machine — persists and manages task state.
actor TaskStateMachine {
    
    static let shared = TaskStateMachine()
    
    private var tasks: [String: TaskRecord] = [:]
    private let storageKey = "task_state_machine"
    private let maxHistory: Int = 100
    
    // MARK: - Task Management
    
    /// Create a new task.
    func createTask(id: String, task: String, initialState: TaskState = .idle) {
        let taskRecord = TaskRecord(id: id, task: task, initialState: initialState)
        tasks[id] = taskRecord
        persist(taskID: id)
        Log("TaskStateMachine: created task \(id)")
    }
    
    /// Transition a task to a new state.
    func transition(taskID: String, to newState: TaskState, reason: String = "") throws {
        guard let task = tasks[taskID] else {
            throw StateMachineError.taskNotFound(taskID)
        }
        
        task.transition(to: newState, reason: reason)
        tasks[taskID] = task
        persist(taskID: taskID)
    }
    
    /// Get task state.
    func getTaskState(taskID: String) -> TaskState? {
        tasks[taskID]?.state
    }
    
    /// Get full task record.
    func getTaskRecord(taskID: String) -> TaskRecord? {
        tasks[taskID]
    }
    
    /// List all tasks.
    func listAllTasks() -> [TaskRecord] {
        Array(tasks.values)
    }
    
    /// List tasks by state.
    func listTasks(by state: TaskState) -> [TaskRecord] {
        Array(tasks.values.filter { $0.state == state })
    }
    
    /// Delete a task.
    func deleteTask(taskID: String) {
        tasks.removeValue(forKey: taskID)
        Log("TaskStateMachine: deleted task \(taskID)")
    }
    
    // MARK: - Persistence
    
    /// Persist a task to disk.
    private func persist(taskID: String) {
        guard let task = tasks[taskID] else { return }
        var allTasks = tasks
        if let data = try? JSONEncoder().encode(allTasks) {
            UserDefaults.standard.set(data, forKey: storageKey)
            Log("TaskStateMachine: persisted task \(taskID)")
        }
    }
    
    /// Restore all tasks from disk.
    func restore() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let loaded = try? JSONDecoder().decode([String: TaskRecord].self, from: data) else {
            Log("TaskStateMachine: no saved state found — starting fresh")
            return
        }
        tasks = loaded
        Log("TaskStateMachine: restored \(tasks.count) tasks from disk")
    }
    
    /// Save all tasks.
    func saveAll() {
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    
    /// Clear all tasks.
    func clearAll() {
        tasks.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
        Log("TaskStateMachine: cleared all tasks")
    }
    
    // MARK: - History Management
    
    /// Limit transition history.
    func limitHistory(for taskID: String) {
        guard var task = tasks[taskID] else { return }
        if task.transitions.count > maxHistory {
            task.transitions = Array(task.transitions.suffix(maxHistory))
            tasks[taskID] = task
            persist(taskID: taskID)
        }
    }
    
    /// Get transition history.
    func getTransitionHistory(taskID: String) -> [TaskRecord.TransitionRecord] {
        tasks[taskID]?.transitions ?? []
    }
    
    // MARK: - Recovery
    
    /// Find tasks that need recovery (failed or retrying).
    func findTasksWithRecovery() -> [TaskRecord] {
        tasks.values.filter { $0.state == .failed || $0.state == .retrying }
    }
    
    /// Recover a failed task.
    func recoverFailedTask(taskID: String) {
        guard var task = tasks[taskID] else { return }
        task.transition(to: .analyzing, reason: "Manual recovery")
        tasks[taskID] = task
        persist(taskID: taskID)
    }
    
    /// Retry a task.
    func retryTask(taskID: String) {
        guard var task = tasks[taskID] else { return }
        task.transition(to: .retrying, reason: "User retry")
        tasks[taskID] = task
        persist(taskID: taskID)
    }
}

// MARK: - Errors

enum StateMachineError: LocalizedError {
    case taskNotFound(String)           // task ID
    case invalidTransition(String)      // task ID
    case persistFailed(String)          // task ID
    case restoreFailed
    
    var errorDescription: String? {
        switch self {
        case .taskNotFound(let id):
            return "Task not found: \(id)"
        case .invalidTransition(let id):
            return "Invalid state transition for task \(id)"
        case .persistFailed(let id):
            return "Failed to persist task \(id)"
        case .restoreFailed:
            return "Failed to restore state from disk"
        }
    }
}
