import CalendarAlarmCore
import Foundation

let usage = """
    usage: CalendarAlarm [--settings | --sync | --status | --enable | --disable | --test-in <seconds> | --ring-now]

      --settings         open the settings window (default when launched from Finder)
      --sync             one background check; run by the LaunchAgent, not by hand
      --status           print background status recorded by the last check
      --enable/--disable register or remove the background LaunchAgent
      --test-in N        ask the background check to ring a test alarm in N seconds
      --ring-now         show a test alarm immediately in this process
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "--sync":
    Sync.run()

case "--status":
    Status.print()

case "--enable":
    do {
        if try Agent.register(store: .standard) { print("re-registered the background agent: it had stopped running here") }
    } catch { fail("enable failed: \(error)") }
    print("background agent: \(Agent.describe(Agent.service.status))")

case "--disable":
    do { try Agent.service.unregister() } catch { fail("disable failed: \(error)") }
    print("background agent: \(Agent.describe(Agent.service.status))")

case "--test-in":
    guard arguments.count == 2, let seconds = TimeInterval(arguments[1]), seconds >= 0 else { fail(usage) }
    let fireAt = Date().addingTimeInterval(seconds)
    do { try Store.standard.updateState { $0.testAlarms.append(fireAt) } } catch { fail("could not write state: \(error)") }
    print("test alarm scheduled for \(fireAt.formatted(date: .omitted, time: .standard))")

case "--events":
    // Diagnostic. Must run as the app (`open -a "Calendar Alarm" --stdout <file> --args --events`), not from a terminal.
    let config = Store.standard.loadConfig()
    print("calendar access: \(CalendarReader.describe(CalendarReader.status))")
    for o in CalendarReader.occurrences(from: Date().addingTimeInterval(-6 * 3600), to: Date().addingTimeInterval(2 * 3600), config: config) {
        let flags = [o.isAllDay ? "all-day" : nil, o.isDeclined ? "declined" : nil, o.isCancelled ? "cancelled" : nil,
                     Planner.isEligible(o, config: config) ? nil : "skipped", o.joinURL == nil ? nil : "join-link"].compactMap { $0 }
        print("\(o.start.formatted(date: .omitted, time: .shortened))  \(o.calendarTitle)  \(o.title)  \(flags.joined(separator: ","))")
    }

case "--ring-now":
    AlarmPresenter.runApp(alarms: [Alarm(occurrence: .test(at: Date().addingTimeInterval(300)), fireAt: Date(), ledgerKeys: [])], store: nil)

case nil, "--settings":
    SettingsController.run()

case let flag? where flag.hasPrefix("-") && !flag.hasPrefix("-psn"):
    fail(usage)

default:
    SettingsController.run()
}
