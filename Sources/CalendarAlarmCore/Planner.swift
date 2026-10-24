import CryptoKit
import Foundation

public enum Planner {
    public enum Action: Equatable, Sendable {
        /// Ring these now, in order.
        case ring([Alarm])
        /// Nothing is due yet, but an alarm fires before the next scheduled sync.
        case wait(until: Date)
        /// Nothing to do before the next sync.
        case idle
    }

    // MARK: Keys

    static func key(_ parts: String...) -> String {
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func seconds(_ date: Date) -> String {
        String(Int(date.timeIntervalSince1970.rounded()))
    }

    public static func leadKey(_ o: Occurrence, minutes: Int) -> String {
        key(o.eventID, seconds(o.start), "lead", String(minutes))
    }

    public static func snoozeKey(_ s: Snooze) -> String {
        key(s.eventID, seconds(s.start), "snooze", seconds(s.fireAt))
    }

    public static func testKey(_ fireAt: Date) -> String {
        key(Occurrence.testEventID, "test", seconds(fireAt))
    }

    // MARK: Planning

    public static func isEligible(_ o: Occurrence, config: Config) -> Bool {
        !o.isCancelled
            && !(config.skipAllDay && o.isAllDay)
            && !(config.skipDeclined && o.isDeclined)
            && !config.disabledCalendarIDs.contains(o.calendarID)
            && !config.skipTitlesContaining.contains { !$0.isEmpty && o.title.localizedCaseInsensitiveContains($0) }
    }

    /// Every alarm implied by the events, snoozes and test requests, fired or not.
    public static func alarms(occurrences: [Occurrence], config: Config, state: State) -> [Alarm] {
        var result: [Alarm] = []
        let eligible = occurrences.filter { isEligible($0, config: config) }
        for o in eligible {
            for minutes in Set(config.leadMinutes) {
                let fireAt = o.start.addingTimeInterval(-TimeInterval(minutes * 60))
                result.append(Alarm(occurrence: o, fireAt: fireAt, ledgerKeys: [leadKey(o, minutes: minutes)]))
            }
        }
        for s in state.snoozes {
            // A snooze whose event was moved, cancelled or declined finds no match and is dropped.
            guard let o = eligible.first(where: { $0.eventID == s.eventID && $0.start == s.start }) else { continue }
            result.append(Alarm(occurrence: o, fireAt: s.fireAt, ledgerKeys: [snoozeKey(s)]))
        }
        for t in state.testAlarms {
            result.append(Alarm(occurrence: .test(at: t), fireAt: t, ledgerKeys: [testKey(t)]))
        }
        return result
    }

    static func pending(_ alarms: [Alarm], now: Date, state: State) -> [Alarm] {
        alarms.filter { a in
            a.occurrence.end > now
                && !a.ledgerKeys.allSatisfy { state.fired[$0] != nil }
                && !a.ledgerKeys.contains { (state.presenting[$0]?.attempts ?? 0) >= State.maxAttempts }
        }
    }

    /// Too late to ring: the alarm was due more than the grace window ago, so the
    /// Mac was asleep or off when it should have rung.
    public static func isMissed(_ alarm: Alarm, now: Date, config: Config) -> Bool {
        alarm.fireAt < now - TimeInterval(config.graceMinutes * 60)
    }

    /// Decide what a sync run should do right now.
    /// - Parameter horizon: how far ahead this run is responsible for; slightly more than the sync interval.
    public static func next(now: Date, alarms: [Alarm], state: State, config: Config, horizon: TimeInterval) -> Action {
        let pending = pending(alarms, now: now, state: state)

        let due = pending.filter { $0.fireAt <= now && !isMissed($0, now: now, config: config) }
        if !due.isEmpty {
            return .ring(merged(due))
        }
        let soonest = pending.filter { $0.fireAt > now && $0.fireAt <= now + horizon }.map(\.fireAt).min()
        if let soonest {
            return .wait(until: soonest)
        }
        return .idle
    }

    /// The next alarm still to come, for status display.
    public static func upcoming(now: Date, alarms: [Alarm], state: State) -> Date? {
        pending(alarms, now: now, state: state).filter { $0.fireAt > now }.map(\.fireAt).min()
    }

    /// One alarm per occurrence, ordered by start time, so stages that come due together ring once.
    static func merged(_ due: [Alarm]) -> [Alarm] {
        var byOccurrence: [String: Alarm] = [:]
        for a in due {
            let id = a.occurrence.eventID + "|" + seconds(a.occurrence.start)
            if var existing = byOccurrence[id] {
                existing.ledgerKeys += a.ledgerKeys
                existing.fireAt = max(existing.fireAt, a.fireAt)
                byOccurrence[id] = existing
            } else {
                byOccurrence[id] = a
            }
        }
        return byOccurrence.values.sorted {
            ($0.occurrence.start, $0.occurrence.title) < ($1.occurrence.start, $1.occurrence.title)
        }
    }
}
