import Foundation
import Testing
@testable import CalendarAlarmCore

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func event(_ id: String, startsIn minutes: Double, length: Double = 30, calendar: String = "cal") -> Occurrence {
    let start = t0.addingTimeInterval(minutes * 60)
    return Occurrence(
        eventID: id, calendarID: calendar, calendarTitle: "Work", title: id,
        start: start, end: start.addingTimeInterval(length * 60)
    )
}

func plan(_ events: [Occurrence], config: Config = Config(), state: State = State(), now: Date = t0) -> Planner.Action {
    let alarms = Planner.alarms(occurrences: events, config: config, state: state)
    return Planner.next(now: now, alarms: alarms, state: state, config: config, horizon: 75)
}

@Suite struct PlannerTests {
    @Test func ringsWhenLeadTimeReached() {
        let action = plan([event("a", startsIn: 5)])
        guard case .ring(let alarms) = action else { Issue.record("expected ring, got \(action)"); return }
        #expect(alarms.map(\.occurrence.eventID) == ["a"])
    }

    @Test func waitsForAlarmInsideHorizon() {
        // 5 min lead, event in 6 min: alarm in 60 s, inside the 75 s horizon.
        #expect(plan([event("a", startsIn: 6)]) == .wait(until: t0.addingTimeInterval(60)))
    }

    @Test func idleWhenAlarmBeyondHorizon() {
        #expect(plan([event("a", startsIn: 7)]) == .idle)
    }

    @Test func ringsLateWithinGrace() {
        // Alarm was due 4 minutes ago (woke from sleep); grace is 5.
        guard case .ring = plan([event("a", startsIn: 1)]) else { Issue.record("expected ring"); return }
    }

    @Test func skipsAlarmPastGrace() {
        var config = Config()
        config.leadMinutes = [10]
        // Due 6 minutes ago, still before the event starts.
        #expect(plan([event("a", startsIn: 4)], config: config) == .idle)
    }

    @Test func neverRingsTwice() {
        let e = event("a", startsIn: 5)
        var state = State()
        guard case .ring(let alarms) = plan([e], state: state) else { Issue.record("expected ring"); return }
        state.settle(alarms[0], at: t0)
        #expect(plan([e], state: state) == .idle)
        #expect(plan([e], state: state, now: t0.addingTimeInterval(30)) == .idle)
    }

    @Test func movedEventRingsAtNewTime() {
        var state = State()
        let original = event("a", startsIn: 5)
        guard case .ring(let alarms) = plan([original], state: state) else { Issue.record("expected ring"); return }
        state.settle(alarms[0], at: t0)
        let moved = event("a", startsIn: 65)
        #expect(plan([moved], state: state, now: t0.addingTimeInterval(3600)) != .idle)
    }

    @Test func cancelledDeclinedAllDayAndDisabledAreSkipped() {
        var cancelled = event("c", startsIn: 5); cancelled.isCancelled = true
        var declined = event("d", startsIn: 5); declined.isDeclined = true
        var allDay = event("e", startsIn: 5); allDay.isAllDay = true
        let disabled = event("f", startsIn: 5, calendar: "off")
        var config = Config()
        config.disabledCalendarIDs = ["off"]
        #expect(plan([cancelled, declined, allDay, disabled], config: config) == .idle)
    }

    @Test func declinedRingsWhenFilterOff() {
        var declined = event("d", startsIn: 5); declined.isDeclined = true
        var config = Config()
        config.skipDeclined = false
        guard case .ring = plan([declined], config: config) else { Issue.record("expected ring"); return }
    }

    @Test func simultaneousEventsQueueInStartOrder() {
        let action = plan([event("b", startsIn: 5), event("a", startsIn: 5), event("c", startsIn: 4.5)])
        guard case .ring(let alarms) = action else { Issue.record("expected ring"); return }
        #expect(alarms.map(\.occurrence.eventID) == ["c", "a", "b"])
    }

    @Test func stagesDueTogetherRingOnce() {
        var config = Config()
        config.leadMinutes = [5, 2]
        // Woke 1 minute before start: both the 5- and 2-minute stages are within grace.
        let e = event("a", startsIn: 1)
        guard case .ring(let alarms) = plan([e], config: config) else { Issue.record("expected ring"); return }
        #expect(alarms.count == 1)
        #expect(alarms[0].ledgerKeys.count == 2)
        var state = State()
        state.settle(alarms[0], at: t0)
        #expect(plan([e], config: config, state: state) == .idle)
    }

    @Test func secondStageRingsAfterFirst() {
        var config = Config()
        config.leadMinutes = [5, 0]
        let e = event("a", startsIn: 5)
        var state = State()
        guard case .ring(let first) = plan([e], config: config, state: state) else { Issue.record("expected ring"); return }
        state.settle(first[0], at: t0)
        let atStart = t0.addingTimeInterval(300)
        guard case .ring(let second) = plan([e], config: config, state: state, now: atStart) else {
            Issue.record("expected second stage"); return
        }
        #expect(second[0].fireAt == e.start)
    }

    @Test func noAlarmAfterEventEnds() {
        var config = Config()
        config.leadMinutes = [0]
        config.graceMinutes = 60
        // Started 20 minutes ago, ended 10 minutes ago.
        #expect(plan([event("a", startsIn: -20, length: 10)], config: config) == .idle)
    }
}

@Suite struct SnoozeTests {
    @Test func snoozeRingsOnceAtNewTime() {
        let e = event("a", startsIn: 5)
        var state = State()
        guard case .ring(let alarms) = plan([e], state: state) else { Issue.record("expected ring"); return }
        state.settle(alarms[0], at: t0)
        state.snooze(alarms[0], minutes: 1, now: t0)
        #expect(state.snoozes.count == 1)

        let later = t0.addingTimeInterval(60)
        guard case .ring(let again) = plan([e], state: state, now: later) else { Issue.record("expected snooze"); return }
        state.settle(again[0], at: later)
        #expect(state.snoozes.isEmpty)
        #expect(plan([e], state: state, now: later.addingTimeInterval(5)) == .idle)
    }

    @Test func snoozeForCancelledEventIsDropped() {
        var e = event("a", startsIn: 5)
        var state = State()
        state.snoozes = [Snooze(eventID: "a", start: e.start, fireAt: t0)]
        e.isCancelled = true
        #expect(plan([e], state: state) == .idle)
    }

    @Test func dismissCancelsPendingSnoozes() {
        let e = event("a", startsIn: 5)
        var state = State()
        state.snoozes = [Snooze(eventID: "a", start: e.start, fireAt: t0.addingTimeInterval(120))]
        state.dismiss(Alarm(occurrence: e, fireAt: t0, ledgerKeys: []))
        #expect(state.snoozes.isEmpty)
    }

    @Test func testAlarmsRingAndSnooze() {
        var state = State()
        state.testAlarms = [t0]
        guard case .ring(let alarms) = plan([], state: state) else { Issue.record("expected ring"); return }
        #expect(alarms[0].occurrence.isTest)
        state.settle(alarms[0], at: t0)
        #expect(state.testAlarms.isEmpty)
        state.snooze(alarms[0], minutes: 5, now: t0)
        #expect(state.testAlarms == [t0.addingTimeInterval(300)])
    }

    @Test func pruneDropsExpiredEntries() {
        var state = State()
        state.fired = ["old": t0.addingTimeInterval(-3 * 86_400), "new": t0]
        state.snoozes = [Snooze(eventID: "a", start: t0, fireAt: t0.addingTimeInterval(-600))]
        state.testAlarms = [t0.addingTimeInterval(-600), t0.addingTimeInterval(60)]
        state.prune(now: t0, config: Config())
        #expect(Array(state.fired.keys) == ["new"])
        #expect(state.snoozes.isEmpty)
        #expect(state.testAlarms == [t0.addingTimeInterval(60)])
    }
}

@Suite struct ConferenceLinkTests {
    @Test(arguments: [
        "https://us02web.zoom.us/j/123456789?pwd=abc",
        "https://meet.google.com/abc-defg-hij",
        "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0?context=y",
        "https://teams.live.com/meet/9312345",
    ])
    func findsSupportedLinks(_ link: String) {
        #expect(ConferenceLink.find(in: ["Join here: \(link) thanks"])?.absoluteString == link)
    }

    @Test(arguments: [
        "http://zoom.us/j/123",
        "https://zoom.us/",
        "https://evilzoom.us/j/123",
        "https://example.com/meet.google.com/abc",
        "no link here",
    ])
    func ignoresOtherText(_ text: String) {
        #expect(ConferenceLink.find(in: [text]) == nil)
    }

    @Test func prefersEarlierField() {
        let url = ConferenceLink.find(in: ["https://meet.google.com/aaa-bbbb-ccc", "https://zoom.us/j/1"])
        #expect(url?.host == "meet.google.com")
    }
}

@Suite struct StoreTests {
    func tempStore() -> Store {
        Store(directory: FileManager.default.temporaryDirectory.appending(path: "calendar-alarm-tests-\(UUID().uuidString)"))
    }

    @Test func missingFilesGiveDefaults() {
        let store = tempStore()
        #expect(store.loadConfig() == Config())
        #expect(store.loadState() == State())
    }

    @Test func configDecodesPartialJSON() throws {
        let store = tempStore()
        try store.ensureDirectory()
        try Data(#"{"leadMinutes":[10,0]}"#.utf8).write(to: store.configURL)
        let config = store.loadConfig()
        #expect(config.leadMinutes == [10, 0])
        #expect(config.graceMinutes == 5)
    }

    @Test func stateRoundTripsWithPrivatePermissions() throws {
        let store = tempStore()
        try store.updateState { $0.testAlarms = [t0] }
        #expect(store.loadState().testAlarms == [t0])
        let mode = try FileManager.default.attributesOfItem(atPath: store.stateURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func runLockIsExclusive() throws {
        let store = tempStore()
        let first = try store.acquireRunLock()
        #expect(first != nil)
        #expect(try store.acquireRunLock() == nil)
        close(first!)
        let again = try store.acquireRunLock()
        #expect(again != nil)
        close(again!)
    }
}
