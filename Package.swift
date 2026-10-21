// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "calendar-alarm",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure planning and state logic. No EventKit or AppKit, so it is fully unit-testable.
        .target(name: "CalendarAlarmCore"),
        // The single app binary: --settings, --sync, --status and friends.
        .executableTarget(
            name: "CalendarAlarm",
            dependencies: ["CalendarAlarmCore"]
        ),
        .testTarget(
            name: "CalendarAlarmCoreTests",
            dependencies: ["CalendarAlarmCore"]
        ),
    ]
)
