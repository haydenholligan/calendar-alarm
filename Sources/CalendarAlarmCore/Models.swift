import Foundation

/// One occurrence of a calendar event, normalized from EventKit. Lives in memory only.
public struct Occurrence: Sendable, Equatable {
    public static let testEventID = "calendar-alarm.test"

    public var eventID: String
    public var calendarID: String
    public var calendarTitle: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var isDeclined: Bool
    public var isCancelled: Bool
    public var joinURL: URL?

    public init(
        eventID: String,
        calendarID: String,
        calendarTitle: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        isDeclined: Bool = false,
        isCancelled: Bool = false,
        joinURL: URL? = nil
    ) {
        self.eventID = eventID
        self.calendarID = calendarID
        self.calendarTitle = calendarTitle
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isDeclined = isDeclined
        self.isCancelled = isCancelled
        self.joinURL = joinURL
    }

    public static func test(at date: Date) -> Occurrence {
        Occurrence(
            eventID: testEventID,
            calendarID: "",
            calendarTitle: "Calendar Alarm",
            title: "Test alarm",
            start: date,
            end: date.addingTimeInterval(60)
        )
    }

    public var isTest: Bool { eventID == Occurrence.testEventID }
}

public struct Alarm: Sendable, Equatable {
    public var occurrence: Occurrence
    public var fireAt: Date
    /// Ledger keys this alarm settles. More than one when several stages for the
    /// same occurrence come due together (for example after waking from sleep).
    public var ledgerKeys: [String]

    public init(occurrence: Occurrence, fireAt: Date, ledgerKeys: [String]) {
        self.occurrence = occurrence
        self.fireAt = fireAt
        self.ledgerKeys = ledgerKeys
    }
}

public struct Config: Codable, Sendable, Equatable {
    /// Calendars are enabled unless listed here, so newly added calendars ring by default.
    public var disabledCalendarIDs: Set<String> = []
    public var leadMinutes: [Int] = [5]
    /// Alarms missed by more than this (sleep, logged out) are skipped, not replayed.
    public var graceMinutes: Int = 5
    public var skipAllDay = true
    public var skipDeclined = true
    /// Full-screen alarm, or a compact floating window when false.
    public var fullScreen = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        disabledCalendarIDs = try c.decodeIfPresent(Set<String>.self, forKey: .disabledCalendarIDs) ?? d.disabledCalendarIDs
        leadMinutes = try c.decodeIfPresent([Int].self, forKey: .leadMinutes) ?? d.leadMinutes
        graceMinutes = try c.decodeIfPresent(Int.self, forKey: .graceMinutes) ?? d.graceMinutes
        skipAllDay = try c.decodeIfPresent(Bool.self, forKey: .skipAllDay) ?? d.skipAllDay
        skipDeclined = try c.decodeIfPresent(Bool.self, forKey: .skipDeclined) ?? d.skipDeclined
        fullScreen = try c.decodeIfPresent(Bool.self, forKey: .fullScreen) ?? d.fullScreen
    }
}

/// An alarm shown but not yet acknowledged.
public struct Presenting: Codable, Sendable, Equatable {
    public var since: Date
    public var attempts: Int

    public init(since: Date, attempts: Int) {
        self.since = since
        self.attempts = attempts
    }
}

public struct Snooze: Codable, Sendable, Equatable {
    public var eventID: String
    public var start: Date
    public var fireAt: Date

    public init(eventID: String, start: Date, fireAt: Date) {
        self.eventID = eventID
        self.start = start
        self.fireAt = fireAt
    }
}

/// Aggregate cost of background sync runs, for measuring the energy trade-off.
public struct RunStats: Codable, Sendable, Equatable {
    public var since: Date
    public var runs = 0
    public var cpuMs = 0
    public var wallMs = 0
    public var peakFootprintBytes: UInt64 = 0
    public var lastFootprintBytes: UInt64 = 0

    public init(since: Date) {
        self.since = since
    }

    public mutating func record(cpuMs: Int, wallMs: Int, peakFootprintBytes: UInt64) {
        runs += 1
        self.cpuMs += cpuMs
        self.wallMs += wallMs
        self.peakFootprintBytes = max(self.peakFootprintBytes, peakFootprintBytes)
        lastFootprintBytes = peakFootprintBytes
    }
}

/// Persisted state. Holds opaque keys and timestamps only, never event titles.
public struct State: Codable, Sendable, Equatable {
    /// How many times an unacknowledged alarm is shown, so a crashing alarm cannot loop.
    public static let maxAttempts = 2

    /// Acknowledged alarms. These never ring again.
    public var fired: [String: Date] = [:]
    /// Alarms on screen. The presenting process holds the run lock, so an entry
    /// seen by a later run means that presenter died before acknowledgment.
    public var presenting: [String: Presenting] = [:]
    public var snoozes: [Snooze] = []
    public var testAlarms: [Date] = []
    public var lastSync: Date?
    public var lastError: String?
    public var calendarAccess: String?
    public var lastEventCount: Int?
    public var nextAlarm: Date?
    public var stats: RunStats?
    /// Where the app was, and which executable file ran, when the agent last
    /// ran. Used to detect a moved or replaced app.
    public var agentBundlePath: String?
    public var agentExecutableID: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fired = try c.decodeIfPresent([String: Date].self, forKey: .fired) ?? [:]
        presenting = try c.decodeIfPresent([String: Presenting].self, forKey: .presenting) ?? [:]
        snoozes = try c.decodeIfPresent([Snooze].self, forKey: .snoozes) ?? []
        testAlarms = try c.decodeIfPresent([Date].self, forKey: .testAlarms) ?? []
        lastSync = try c.decodeIfPresent(Date.self, forKey: .lastSync)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        calendarAccess = try c.decodeIfPresent(String.self, forKey: .calendarAccess)
        lastEventCount = try c.decodeIfPresent(Int.self, forKey: .lastEventCount)
        nextAlarm = try c.decodeIfPresent(Date.self, forKey: .nextAlarm)
        stats = try c.decodeIfPresent(RunStats.self, forKey: .stats)
        agentBundlePath = try c.decodeIfPresent(String.self, forKey: .agentBundlePath)
        agentExecutableID = try c.decodeIfPresent(String.self, forKey: .agentExecutableID)
    }

    /// Drop ledger entries and snoozes that can no longer matter.
    public mutating func prune(now: Date, config: Config) {
        let grace = TimeInterval(config.graceMinutes * 60)
        fired = fired.filter { now.timeIntervalSince($0.value) < 2 * 86_400 }
        presenting = presenting.filter { now.timeIntervalSince($0.value.since) < 2 * 86_400 }
        snoozes.removeAll { $0.fireAt < now - grace }
        testAlarms.removeAll { $0 < now - grace }
    }

    /// Record that an alarm is about to be shown. Until it is acknowledged, a
    /// later run may show it again (see `maxAttempts`).
    public mutating func begin(_ alarm: Alarm, at now: Date) {
        for key in alarm.ledgerKeys {
            presenting[key] = Presenting(since: now, attempts: (presenting[key]?.attempts ?? 0) + 1)
        }
    }

    /// Record that the user acted on an alarm, so it never rings again.
    public mutating func acknowledge(_ alarm: Alarm, at now: Date) {
        let keys = Set(alarm.ledgerKeys)
        for key in keys {
            fired[key] = now
            presenting[key] = nil
        }
        snoozes.removeAll { keys.contains(Planner.snoozeKey($0)) }
        testAlarms.removeAll { keys.contains(Planner.testKey($0)) }
    }

    /// Dismissing an alarm also cancels any snoozes still pending for the same occurrence.
    public mutating func dismiss(_ alarm: Alarm, at now: Date) {
        acknowledge(alarm, at: now)
        let o = alarm.occurrence
        snoozes.removeAll { $0.eventID == o.eventID && $0.start == o.start }
    }

    public mutating func snooze(_ alarm: Alarm, minutes: Int, now: Date) {
        dismiss(alarm, at: now)
        let fireAt = now.addingTimeInterval(TimeInterval(minutes * 60))
        if alarm.occurrence.isTest {
            testAlarms.append(fireAt)
        } else {
            snoozes.append(Snooze(eventID: alarm.occurrence.eventID, start: alarm.occurrence.start, fireAt: fireAt))
        }
    }
}
