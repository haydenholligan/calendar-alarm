import CalendarAlarmCore
import Foundation
import ServiceManagement

/// The bundled LaunchAgent that runs `--sync` every 60 seconds.
enum Agent {
    static var service: SMAppService { .agent(plistName: "com.corseapps.calendaralarm.sync.plist") }

    /// Identifies the executable file on disk; changes when the app is rebuilt or replaced.
    static func executableID() -> String? {
        guard let path = Bundle.main.executablePath,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let inode = attributes[.systemFileNumber], let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return "\(inode)-\(Int(modified.timeIntervalSince1970))"
    }

    /// Register the agent, or re-register it if it may be broken. After the app
    /// moves, or is replaced by a build with a different code requirement (any
    /// ad-hoc rebuild), every run fails with EX_CONFIG while status still says
    /// enabled. Returns true if it re-registered.
    @discardableResult
    static func register(store: Store) throws -> Bool {
        let state = store.loadState()
        let moved = state.agentBundlePath.map { $0 != Bundle.main.bundlePath } ?? false
        let replaced = state.agentExecutableID.map { $0 != executableID() } ?? false
        let stale = state.lastSync.map { Date().timeIntervalSince($0) > 150 } ?? true
        if service.status == .enabled, moved || replaced || stale {
            // Unregistering stops a running check, which may be ringing; leave it alone if so.
            guard let lock = try store.acquireRunLock() else { return false }
            defer { close(lock) }
            try service.unregister()
            // Unregistering settles asynchronously; registering before it has
            // leaves the stale registration in place.
            let deadline = Date().addingTimeInterval(5)
            while service.status != .notRegistered, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            try service.register()
            return true
        }
        try service.register()
        return false
    }

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
