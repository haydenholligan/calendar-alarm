import ServiceManagement

/// The bundled LaunchAgent that runs `--sync` every 60 seconds.
enum Agent {
    static var service: SMAppService { .agent(plistName: "com.corseapps.calendaralarm.sync.plist") }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "enabled"
        case .requiresApproval: "needs approval in System Settings › General › Login Items"
        case .notRegistered: "off"
        case .notFound: "not found (is the app installed in /Applications?)"
        @unknown default: "unknown"
        }
    }
}
