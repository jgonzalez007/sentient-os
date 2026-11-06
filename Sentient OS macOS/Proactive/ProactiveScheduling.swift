//
//  ProactiveScheduling.swift
//  Sentient OS macOS
//
//  Phase 4.5: Proactive scheduling — time-aware suggestions (e.g., "your flight is in 2 hours").
//  Integrates with Calendar, Mail, and Knowledge Base to provide contextual, time-sensitive
//  intelligence before the user needs it.
//
//  Key methods:
//   - schedule(event:) → schedule a proactive event
//   - triggerAt(date:action:) → trigger at a specific time
//   - triggerIn(seconds:action:) → trigger after a delay
//   - triggerRecurring(pattern:) → trigger on a pattern
//   - getUpcomingTriggers() → get upcoming triggers
//   - cancelTrigger(id:) → cancel a trigger
//
//  Usage: `ProactiveScheduling.triggerAt(date: departureTime, action: .sendNotification("Flight departing"))`
//
//  Doc: Scheduling/Documentation - Proactive Scheduling.md
//

import Foundation
import NotificationCenter

/// Proactive trigger — when and how to trigger an action.
struct ProactiveTrigger: Codable, Sendable {
    let id: String
    let action: ProactiveAction
    let triggerDate: Date?
    let triggerSeconds: TimeInterval?
    let recurrencePattern: RecurrencePattern?
    let isFired: Bool
    let lastFiredAt: Date?
    let nextFireDate: Date?
    let createdAt: Date
    
    init(id: String, action: ProactiveAction, triggerDate: Date? = nil,
         triggerSeconds: TimeInterval? = nil, recurrencePattern: RecurrencePattern? = nil) {
        self.id = id
        self.action = action
        self.triggerDate = triggerDate
        self.triggerSeconds = triggerSeconds
        self.recurrencePattern = recurrencePattern
        self.isFired = false
        self.lastFiredAt = nil
        self.nextFireDate = triggerDate
        self.createdAt = Date()
    }
    
    var shouldFire: Bool {
        guard let date = triggerDate else { return false }
        return date <= Date() && !isFired
    }
    
    var nextFire: Date? {
        guard let pattern = recurrencePattern else { return triggerDate }
        return pattern.nextFire(from: triggerDate ?? Date())
    }
}

/// Recurrence pattern — how often to repeat a trigger.
enum RecurrencePattern: Codable, Sendable {
    case minutely(interval: Int)
    case hourly(interval: Int)
    case daily(interval: Int)
    case weekly(interval: Int, weekday: Int)  // weekday: 0=Sunday
    case monthly(interval: Int, day: Int)
    case custom(component: Calendar.Component, value: Int)
    
    var label: String {
        switch self {
        case .minutely(let i): return "Every \(i) minutes"
        case .hourly(let i): return "Every \(i) hours"
        case .daily(let i): return "Every \(i) days"
        case .weekly(let i, let w): return "Weekly (\(weekdayName(w)))"
        case .monthly(let i, let d): return "Monthly (day \(d))"
        case .custom(let c, let v): return "Every \(v) \(c.rawValue)"
        }
    }
    
    func nextFire(from date: Date) -> Date {
        let calendar = Calendar.current
        let interval = calendar.dateComponents([self.component], from: date, to: calendar.startOfDay(for: date))
        return calendar.date(byAdding: self.component, value: self.value, to: date) ?? date
    }
    
    private var component: Calendar.Component {
        switch self {
        case .minutely: return .minute
        case .hourly: return .hour
        case .daily: return .day
        case .weekly: return .weekday
        case .monthly: return .day
        case .custom(let c, _): return c
        }
    }
    
    private func weekdayName(_ weekday: Int) -> String {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return names[(weekday - 1 + 7) % 7]
    }
}

/// Proactive scheduling engine — manages time-aware triggers.
actor ProactiveScheduling {
    
    static let shared = ProactiveScheduling()
    
    private var triggers: [String: ProactiveTrigger] = [:]
    private var fireQueue: [UNNotificationRequest] = []
    private let userNotificationCenter = UNUserNotificationCenter.current()
    
    // MARK: - Trigger Management
    
    /// Schedule a proactive trigger.
    func schedule(trigger: ProactiveTrigger) {
        triggers[trigger.id] = trigger
        
        // If it has a trigger date, schedule a local notification
        if let date = trigger.triggerDate {
            let content = UNMutableNotificationContent()
            content.title = "Sentient OS"
            content.body = "Proactive trigger: \(trigger.action.label)"
            content.sound = .default
            content.categoryIdentifier = "proactive"
            
            let calendar = Calendar.current
            let components = calendar.dateComponents(in: calendar.timeZone, from: date)
            let triggerObj = UNCalendarNotificationTrigger(dateMatching: components, repeats: trigger.recurrencePattern != nil)
            
            let request = UNNotificationRequest(identifier: trigger.id, content: content, trigger: triggerObj)
            fireQueue.append(request)
        }
        
        Log("ProactiveScheduling: scheduled trigger \(trigger.id) at \(trigger.triggerDate?.description ?? "recurring")")
    }
    
    /// Trigger at a specific date.
    func triggerAt(date: Date, action: ProactiveAction) {
        let trigger = ProactiveTrigger(id: UUID().uuidString, action: action, triggerDate: date)
        schedule(trigger: trigger)
    }
    
    /// Trigger after a delay.
    func triggerIn(seconds: TimeInterval, action: ProactiveAction) {
        let fireDate = Date().addingTimeInterval(seconds)
        let trigger = ProactiveTrigger(id: UUID().uuidString, action: action, triggerDate: fireDate)
        schedule(trigger: trigger)
    }
    
    /// Trigger on a recurring pattern.
    func triggerRecurring(pattern: RecurrencePattern, action: ProactiveAction, startDate: Date? = nil) {
        let trigger = ProactiveTrigger(
            id: UUID().uuidString,
            action: action,
            triggerDate: startDate ?? Date(),
            recurrencePattern: pattern
        )
        schedule(trigger: trigger)
    }
    
    /// Get upcoming triggers.
    func getUpcomingTriggers() -> [ProactiveTrigger] {
        triggers.values.filter { $0.triggerDate == nil || $0.triggerDate! > Date() }
            .sorted { ($0.triggerDate ?? Date.distantFuture) < ($1.triggerDate ?? Date.distantFuture) }
    }
    
    /// Cancel a trigger.
    func cancelTrigger(id: String) {
        triggers.removeValue(forKey: id)
        Log("ProactiveScheduling: cancelled trigger \(id)")
    }
    
    /// Fire a trigger immediately.
    func fireImmediately(id: String) async {
        guard let trigger = triggers[id] else { return }
        
        // Execute the action
        let result = await ProactiveExecutorOverhaul.shared.fire(action: trigger.action)
        
        // Update trigger
        var updatedTrigger = trigger
        updatedTrigger.isFired = true
        updatedTrigger.lastFiredAt = Date()
        
        // Handle recurrence
        if let pattern = trigger.recurrencePattern {
            if let nextFire = pattern.nextFire(from: trigger.triggerDate ?? Date()) {
                updatedTrigger.triggerDate = nextFire
                updatedTrigger.isFired = false
            } else {
                // No more fires — remove
                triggers.removeValue(forKey: id)
                Log("ProactiveScheduling: trigger \(id) completed (no more fires)")
                return
            }
        } else {
            // Single trigger — mark as done
            Log("ProactiveScheduling: trigger \(id) fired successfully")
        }
        
        triggers[id] = updatedTrigger
        Log("ProactiveScheduling: fired trigger \(id): \(result.success ? "success" : "failed")")
    }
    
    /// Check and fire all due triggers.
    func checkAndFireDueTriggers() async {
        for (id, trigger) in triggers where trigger.shouldFire {
            await self.fireImmediately(id: id)
        }
    }
    
    // MARK: - Scheduling Helpers
    
    /// Schedule a trigger N minutes before an event.
    func scheduleBefore(event: Date, minutesBefore: Int, action: ProactiveAction) {
        let triggerDate = event.addingTimeInterval(-Double(minutesBefore) * 60)
        let trigger = ProactiveTrigger(id: UUID().uuidString, action: action, triggerDate: triggerDate)
        schedule(trigger: trigger)
    }
    
    /// Schedule recurring daily trigger at a specific time.
    func scheduleDaily(time: DateComponents, action: ProactiveAction) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let triggerDate = calendar.date(from: today.dateComponents + time) ?? Date()
        let pattern = RecurrencePattern.daily(interval: 1)
        let trigger = ProactiveTrigger(id: UUID().uuidString, action: action, triggerDate: triggerDate, recurrencePattern: pattern)
        schedule(trigger: trigger)
    }
    
    /// Schedule a weekly trigger.
    func scheduleWeekly(weekday: Int, hour: Int, minute: Int, action: ProactiveAction) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var timeComponents = DateComponents()
        timeComponents.weekday = weekday
        timeComponents.hour = hour
        timeComponents.minute = minute
        let triggerDate = calendar.date(from: today.dateComponents + timeComponents) ?? Date()
        let pattern = RecurrencePattern.weekly(interval: 1, weekday: weekday)
        let trigger = ProactiveTrigger(id: UUID().uuidString, action: action, triggerDate: triggerDate, recurrencePattern: pattern)
        schedule(trigger: trigger)
    }
    
    // MARK: - Management
    
    /// Get all triggers.
    func getAllTriggers() -> [ProactiveTrigger] {
        Array(triggers.values)
    }
    
    /// Clear all triggers.
    func clearAllTriggers() {
        triggers.removeAll()
        Log("ProactiveScheduling: cleared all triggers")
    }
    
    /// Get trigger count.
    var triggerCount: Int {
        triggers.count
    }
}

// MARK: - Date Components Extension

extension DateComponents {
    static func + (left: DateComponents, right: DateComponents) -> DateComponents {
        var result = left
        if let hour = right.hour { result.hour = (left.hour ?? 0) + hour }
        if let minute = right.minute { result.minute = (left.minute ?? 0) + minute }
        if let second = right.second { result.second = (left.second ?? 0) + second }
        return result
    }
}
