import CalendarAlarmCore
@preconcurrency import EventKit
import Foundation

enum CalendarReader {
    static var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    static func describe(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess: "full access"
        case .writeOnly: "write-only (needs full access)"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not requested"
        @unknown default: "unknown"
        }
    }

    /// Fetch occurrences overlapping the range from a fresh store, so each call
    /// sees the Calendar database as it is now.
    static func occurrences(from start: Date, to end: Date, config: Config) -> [Occurrence] {
        let store = EKEventStore()
        let calendars = store.calendars(for: .event).filter { !config.disabledCalendarIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).map(Occurrence.init(event:))
    }
}

extension Occurrence {
    init(event: EKEvent) {
        let fields = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
        self.init(
            eventID: event.eventIdentifier ?? event.calendarItemIdentifier,
            calendarID: event.calendar.calendarIdentifier,
            calendarTitle: event.calendar.title,
            title: event.title ?? "Untitled event",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            isDeclined: event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined,
            isCancelled: event.status == .canceled,
            joinURL: ConferenceLink.find(in: fields)
        )
    }
}
