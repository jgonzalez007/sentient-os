//
//  EventKitBackgroundFetch.swift
//  Sentient OS macOS
//
//  Phase 1.6: EventKit background fetch support for Apple Calendar data.
//
//  Provides a background-aware EventKit fetcher that:
//  - Requests proper EKEventStore authorization (event level)
//  - Fetches calendar events within a configurable date range
//  - Uses predicateForEvents(start:end:) for efficient querying
//  - Maps events to a consistent format matching the existing Event model
//  - Handles user declined authorization gracefully
//  - Returns results via a completion callback suitable for background tasks
//
//  Integrates with the existing AppleCalendarSource.Event model for
//  consistency across the ingestion pipeline.
//

import Foundation
import EventKit

// MARK: - CalendarEvent

/// A unified calendar event representation that matches the existing
/// `AppleCalendarSource.Event` model. Used as the output of the
/// EventKit background fetcher.
struct CalendarEvent: Sendable, Equatable {
    let eventIdentifier: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let notes: String?
    let calendarName: String
    let isAllDay: Bool
    let status: EKEventStatus
    let isRecurring: Bool

    static func == (lhs: CalendarEvent, rhs: CalendarEvent) -> Bool {
        lhs.eventIdentifier == rhs.eventIdentifier &&
        lhs.title == rhs.title &&
        lhs.startDate == rhs.startDate &&
        lhs.endDate == rhs.endDate
    }
}

// MARK: - EventKitStatus

/// Authorization status for EventKit access.
enum EventKitStatus: Sendable, CustomStringConvertible {
    case notDetermined
    case restricted
    case denied
    case fullAccess

    var description: String {
        switch self {
        case .notDetermined: return "Not determined"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .fullAccess: return "Full access"
        }
    }
}

// MARK: - EventKitBackgroundFetch

/// Background-aware EventKit fetcher for Apple Calendar data.
///
/// Fetches calendar events within a configurable date range,
/// maps them to the standard `CalendarEvent` model, and handles
/// authorization gracefully (including user declined).
///
/// The fetcher supports both foreground and background contexts:
/// - In foreground: uses EKEventStore directly
/// - In background (BGAppRefreshTask): uses a fresh EKEventStore
///   per fetch to avoid stale cache issues (matching AppleCalendarSource pattern)
///
@Observable
final class EventKitBackgroundFetch: @unchecked Sendable {

    // MARK: - FetchResult

    /// Result of a calendar event fetch operation.
    struct FetchResult: Sendable {
        let events: [CalendarEvent]
        let calendarCount: Int
        let error: Error?
        let fetchDuration: TimeInterval

        /// Whether the fetch completed without errors.
        var succeeded: Bool { error == nil }

        /// A human-readable summary of the fetch.
        var summary: String {
            if let error {
                return "Failed: \(error.localizedDescription) (\(events.count) events fetched before error)"
            }
            return "Fetched \(events.count) events from \(calendarCount) calendars"
        }
    }

    // MARK: - Singleton

    /// Shared instance for background fetch coordination.
    static let shared = EventKitBackgroundFetch()

    // MARK: - Properties

    private let queue = DispatchQueue(label: "ai.sentient.eventkit.fetch", qos: .utility)
    private var lastFetchDate: Date?
    private let maxEventsPerFetch: Int = 2_000

    // MARK: - Authorization

    /// Check the current EventKit authorization status.
    /// Returns `.notDetermined` if the user has not yet been asked.
    static func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// A higher-level view of the authorization status.
    static func status() -> EventKitStatus {
        switch authorizationStatus() {
        case .fullAccess: return .fullAccess
        case .restricted: return .restricted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// Whether the app has full event access.
    static var hasAccess: Bool {
        authorizationStatus() == .fullAccess
    }

    /// Request EventKit access asynchronously.
    /// Returns `true` if granted, `false` if denied or an error occurred.
    /// If the user has already declined, this will show the system dialog again
    /// (but the user's choice may be cached by the system).
    static func requestAccess() async -> Bool {
        let store = EKEventStore()
        return await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { granted, error in
                if let error {
                    Log("EventKitBackgroundFetch: authorization error — \(error.localizedDescription)")
                    continuation.resume(returning: false)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    // MARK: - Fetch Events

    /// Fetch calendar events within the given date range.
    ///
    /// This is the primary API for retrieving calendar data. It:
    /// 1. Checks authorization status first
    /// 2. Creates a fresh EKEventStore (never reuses across runs)
    /// 3. Builds a predicate for efficient querying
    /// 4. Maps events to `CalendarEvent` model
    /// 5. Handles errors gracefully (permission, no selection, etc.)
    ///
    /// - Parameters:
    ///   - start: The inclusive start of the date range.
    ///   - end: The exclusive end of the date range.
    ///   - calendarIDs: Optional set of specific calendar identifiers
    ///     to filter to. Empty set means "all calendars".
    ///   - completion: Called with the fetch result on the main queue.
    ///
    func fetchEvents(
        start: Date,
        end: Date,
        calendarIDs: Set<String> = [],
        completion: @escaping (FetchResult) -> Void
    ) {
        let fetchStart = Date()

        // Check authorization before doing any work.
        let status = Self.authorizationStatus()
        if status != .fullAccess {
            let error = EventKitError(
                code: .authorizationDenied,
                message: "EventKit authorization is \(Self.status().description). " +
                         "Request access before fetching events."
            )
            let result = FetchResult(
                events: [],
                calendarCount: 0,
                error: error,
                fetchDuration: Date().timeIntervalSince(fetchStart)
            )
            MainActor.ensure { completion(result) }
            return
        }

        // Perform the actual fetch on the utility queue.
        queue.async { [weak self] in
            guard let self else {
                let result = FetchResult(events: [], calendarCount: 0,
                                         error: EventKitError(code: .cancelled, message: "Fetch cancelled"),
                                         fetchDuration: Date().timeIntervalSince(fetchStart))
                MainActor.ensure { completion(result) }
                return
            }

            do {
                let store = EKEventStore()  // fresh for each fetch
                let (events, calendarCount) = try self.fetchFromStore(store, start: start, end: end, calendarIDs: calendarIDs)
                let duration = Date().timeIntervalSince(fetchStart)

                self.lastFetchDate = Date()

                let result = FetchResult(
                    events: events,
                    calendarCount: calendarCount,
                    error: nil,
                    fetchDuration: duration
                )
                MainActor.ensure { completion(result) }

            } catch {
                let result = FetchResult(
                    events: [],
                    calendarCount: 0,
                    error: error,
                    fetchDuration: Date().timeIntervalSince(fetchStart)
                )
                MainActor.ensure { completion(result) }
            }
        }
    }

    /// Fetch a single page of events, bounded by the max limit.
    /// Returns events and the number of calendars found.
    @discardableResult
    private func fetchFromStore(
        _ store: EKEventStore,
        start: Date,
        end: Date,
        calendarIDs: Set<String>
    ) throws -> ([CalendarEvent], Int) {
        // Determine which calendars to query.
        let calendars: [EKCalendar]
        if calendarIDs.isEmpty {
            calendars = store.calendars(for: .event)
        } else {
            calendars = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        }

        if calendars.isEmpty {
            throw EventKitError(code: .noCalendars, message: "No event calendars available")
        }

        // Build an efficient predicate for the date range.
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)

        // Fetch events in batches to respect the maxEventsPerFetch limit.
        var allEvents: [CalendarEvent] = []
        var exceededLimit = false

        store.enumerateEvents(matching: predicate) { event, stop in
            guard allEvents.count < maxEventsPerFetch else {
                exceededLimit = true
                stop.pointee = true
                return
            }
            guard let mapped = mapEvent(event, calendars: calendars) else { return }
            allEvents.append(mapped)
        }

        if exceededLimit {
            throw EventKitError(
                code: .limitExceeded,
                message: "Exceeded \(maxEventsPerFetch) event limit. Fetch a narrower date range."
            )
        }

        return (allEvents, calendars.count)
    }

    /// Map an EKEvent to a CalendarEvent, handling edge cases.
    private func mapEvent(_ event: EKEvent, calendars: [EKCalendar]) -> CalendarEvent? {
        guard let rawStart = event.startDate, let rawEnd = event.endDate,
              rawStart <= rawEnd,
              rawStart.timeIntervalSince1970.isFinite,
              rawEnd.timeIntervalSince1970.isFinite else {
            return nil
        }

        let title = event.title ?? ""
        let location = event.location
        let notes = event.notes
        let calendarName = event.calendar.title
        let isAllDay = event.isAllDay
        let isRecurring = event.isRecurrenceEvent

        return CalendarEvent(
            eventIdentifier: event.calendarItemIdentifier,
            title: title,
            startDate: rawStart,
            endDate: rawEnd,
            location: location,
            notes: notes,
            calendarName: calendarName,
            isAllDay: isAllDay,
            status: eventStatus(from: event.status),
            isRecurring: isRecurring
        )
    }

    /// Map an EKEvent status raw value to our typed enum.
    private func eventStatus(from rawValue: Int) -> EKEventStatus {
        switch rawValue {
        case 0: return .confirmed
        case 1: return .tentative
        case 2: return .cancelled
        default: return .unknown
        }
    }

    // MARK: - Background Task Integration

    /// Schedule a background refresh task for calendar data.
    /// Call this during app launch to enable system-level background wake-ups.
    ///
    /// On macOS, BGTaskScheduler is not available, but this method
    /// documents the intended integration point for the Info.plist
    /// `BGTaskSchedulerPermittedTaskIdentifiers` array.
    static func scheduleBackgroundRefresh() {
        #if os(macOS)
        // macOS does not support BGTaskScheduler. The background refresh
        // is instead triggered by app launch or a custom timer.
        // The required Info.plist entries for macOS are:
        // - BGTaskSchedulerPermittedTaskIdentifiers (documented, no effect)
        // - NSCalendarsFullAccessUsageDescription (required for EKEventStore)
        #else
        // iOS/macCatalyst: register with BGTaskScheduler.
        BGTaskScheduler.shared.register(
            withIdentifier: AppleCalendarSourceBackgroundIdentifiers.appRefresh,
            parameters: nil
        ) { task in
            task.expirationHandler = {
                Log("EventKitBackgroundFetch: app refresh task expired")
            }
            Self.shared.fetchEvents(
                start: Date().addingTimeInterval(-1800),  // last 30 min
                end: Date().addingTimeInterval(3600),     // next 1 hour
                completion: { result in
                    task.setTaskCompleted(success: result.succeeded)
                }
            )
        }

        BGTaskScheduler.shared.register(
            withIdentifier: AppleCalendarSourceBackgroundIdentifiers.processing,
            parameters: nil
        ) { task in
            // Full snapshot: fetch a wider window for rebuild.
            let calendar = Calendar(identifier: .gregorian)
            let now = Date()
            let day = calendar.startOfDay(for: now)
            let lower = calendar.date(byAdding: .day, value: -7, to: day)!
            let upper = calendar.date(byAdding: .day, value: 31, to: day)!

            Self.shared.fetchEvents(start: lower, end: upper, completion: { result in
                task.setTaskCompleted(success: result.succeeded)
            })
        }
        #endif
    }

    /// Check if background fetch is appropriate for this source.
    static var prefersBackgroundFetch: Bool {
        hasAccess
    }

    /// The expected refresh interval in seconds.
    static let backgroundRefreshInterval: TimeInterval = 1800  // 30 minutes
}

// MARK: - EventKitError

/// Errors specific to EventKit fetch operations.
enum EventKitError: LocalizedError, Sendable {
    case authorizationDenied
    case noCalendars
    case limitExceeded
    case cancelled
    case storeInitializationFailed(String)
    case invalidEvent(String)

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "EventKit authorization is required. Check System Settings > Privacy > Calendars."
        case .noCalendars:
            return "No event calendars are available."
        case .limitExceeded:
            return "Event count exceeded the fetch limit. Try a narrower date range."
        case .cancelled:
            return "The fetch operation was cancelled."
        case .storeInitializationFailed(let detail):
            return "Failed to initialize EventKit store: \(detail)"
        case .invalidEvent(let id):
            return "An event was invalid: \(id)"
        }
    }
}

// MARK: - AppleCalendarSourceBackgroundIdentifiers

/// Background fetch identifiers for integration with BGTaskScheduler.
/// Add these to your Info.plist `BGTaskSchedulerPermittedTaskIdentifiers` array.
enum AppleCalendarSourceBackgroundIdentifiers {
    /// Short-lived refresh: fetches new events (15-30 min window).
    static let appRefresh = "ai.sentient.calendar.refresh"

    /// Long-lived processing: full snapshot capture (up to 30 min).
    static let processing = "ai.sentient.calendar.process"
}
