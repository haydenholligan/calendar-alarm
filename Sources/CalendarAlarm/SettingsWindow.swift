import AppKit
import CalendarAlarmCore
@preconcurrency import EventKit
import ServiceManagement

/// The on-demand settings window. The app quits when it closes.
@MainActor
final class SettingsController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let leadChoices = [0, 1, 2, 5, 10, 15, 30]

    private let store = Store.standard
    private var config = Store.standard.loadConfig()
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered, defer: false
    )
    private let accessLabel = NSTextField(wrappingLabelWithString: "")
    private let accessButton = NSButton(title: "", target: nil, action: nil)
    private let agentCheckbox = NSButton(checkboxWithTitle: "Ring alarms in the background", target: nil, action: nil)
    private let agentLabel = NSTextField(wrappingLabelWithString: "")
    private let leadPopup = NSPopUpButton()
    private let fullScreenCheckbox = NSButton(checkboxWithTitle: "Cover the whole screen", target: nil, action: nil)
    private let calendarsStack = NSStackView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    static func run() {
        let app = NSApplication.shared
        let controller = SettingsController()
        app.delegate = controller
        app.setActivationPolicy(.regular)
        app.mainMenu = mainMenu()
        app.run()
    }

    static func mainMenu() -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit Calendar Alarm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let windowItem = NSMenuItem()
        windowItem.submenu = NSMenu(title: "Window")
        windowItem.submenu?.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(appItem)
        menu.addItem(windowItem)
        return menu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Agent.service.status == .enabled { _ = try? Agent.register(store: store) }
        buildWindow()
        refresh()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidBecomeActive(_ notification: Notification) { refresh() }

    // MARK: Layout

    private func buildWindow() {
        window.title = "Calendar Alarm"
        window.delegate = self
        window.isReleasedWhenClosed = false

        accessButton.target = self
        accessButton.action = #selector(accessClicked)
        agentCheckbox.target = self
        agentCheckbox.action = #selector(agentToggled)
        for minutes in Self.leadChoices {
            leadPopup.addItem(withTitle: minutes == 0 ? "At start time" : "\(minutes) min before")
        }
        leadPopup.target = self
        leadPopup.action = #selector(leadChanged)
        fullScreenCheckbox.target = self
        fullScreenCheckbox.action = #selector(fullScreenToggled)
        calendarsStack.orientation = .vertical
        calendarsStack.alignment = .leading
        calendarsStack.spacing = 6
        for label in [accessLabel, agentLabel, statusLabel] {
            label.preferredMaxLayoutWidth = 480
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let clip = FlippedView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(calendarsStack)
        calendarsStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = clip
        NSLayoutConstraint.activate([
            calendarsStack.topAnchor.constraint(equalTo: clip.topAnchor),
            calendarsStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            calendarsStack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            calendarsStack.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            clip.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 180),
        ])

        let ringNow = NSButton(title: "Ring Now", target: self, action: #selector(ringNow))
        let testBackground = NSButton(title: "Test Background Alarm in 1 Minute", target: self, action: #selector(testBackground))
        let leadRow = NSStackView(views: [NSTextField(labelWithString: "Alert:"), leadPopup])
        let uninstall = NSButton(title: "Uninstall…", target: self, action: #selector(uninstallClicked))

        let stack = NSStackView(views: [
            heading("Calendar access"), accessLabel, accessButton,
            heading("Background alarms"), agentCheckbox, agentLabel,
            heading("Alerts"), leadRow, fullScreenCheckbox,
            heading("Calendars"), scroll,
            NSStackView(views: [ringNow, testBackground]),
            statusLabel,
            uninstall,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for view in [accessLabel, agentLabel, statusLabel, scroll] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            // The window takes its height from the content.
            content.widthAnchor.constraint(equalToConstant: 520),
        ])
        window.contentView = content
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    // MARK: State

    private func refresh() {
        let access = CalendarReader.status
        accessLabel.stringValue = "Calendar Alarm reads events already synced into macOS Calendar (iCloud, Google, Exchange, local). Access: \(CalendarReader.describe(access))."
        switch access {
        case .fullAccess:
            accessButton.isHidden = true
        case .notDetermined:
            accessButton.isHidden = false
            accessButton.title = "Grant Calendar Access…"
        default:
            accessButton.isHidden = false
            accessButton.title = "Open Privacy Settings…"
        }

        let agentStatus = Agent.service.status
        agentCheckbox.state = agentStatus == .enabled || agentStatus == .requiresApproval ? .on : .off
        agentLabel.stringValue = "Checks Calendar every 60 seconds with a short-lived process; nothing stays running between checks. Status: \(Agent.describe(agentStatus))."

        let lead = config.leadMinutes.first ?? 5
        leadPopup.selectItem(at: Self.leadChoices.firstIndex(of: lead) ?? Self.leadChoices.firstIndex(of: 5)!)
        fullScreenCheckbox.state = config.fullScreen ? .on : .off
        if config.leadMinutes.count > 1 {
            leadPopup.toolTip = "config.json lists several lead times; choosing here replaces them with one."
        }

        calendarsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if access == .fullAccess {
            let calendars = EKEventStore().calendars(for: .event)
                .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
            for calendar in calendars {
                let box = NSButton(checkboxWithTitle: "\(calendar.title) — \(calendar.source.title)", target: self, action: #selector(calendarToggled(_:)))
                box.identifier = NSUserInterfaceItemIdentifier(calendar.calendarIdentifier)
                box.state = config.disabledCalendarIDs.contains(calendar.calendarIdentifier) ? .off : .on
                calendarsStack.addArrangedSubview(box)
            }
        }

        let state = store.loadState()
        var lines: [String] = []
        if let lastSync = state.lastSync {
            lines.append("Last background check: \(lastSync.formatted(.relative(presentation: .named))).")
        } else {
            lines.append("No background check has run yet.")
        }
        if let error = state.lastError { lines.append(error) }
        if let next = state.nextAlarm { lines.append("Next alarm: \(next.formatted(date: .abbreviated, time: .shortened)).") }
        statusLabel.stringValue = lines.joined(separator: " ")
    }

    private func saveConfig() {
        do {
            try store.saveConfig(config)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: Actions

    @objc private func accessClicked() {
        if CalendarReader.status == .notDetermined {
            let eventStore = EKEventStore()
            Task { @MainActor in
                _ = try? await eventStore.requestFullAccessToEvents()
                self.refresh()
            }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func agentToggled() {
        do {
            if agentCheckbox.state == .on {
                try Agent.register(store: store)
                if Agent.service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } else {
                try Agent.service.unregister()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
        refresh()
    }

    @objc private func leadChanged() {
        config.leadMinutes = [Self.leadChoices[leadPopup.indexOfSelectedItem]]
        saveConfig()
    }

    @objc private func fullScreenToggled() {
        config.fullScreen = fullScreenCheckbox.state == .on
        saveConfig()
    }

    @objc private func uninstallClicked() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Calendar Alarm?"
        alert.informativeText = "This stops background alarms, deletes Calendar Alarm's settings and history, removes its Calendar permission, and moves the app to the Trash. Your calendar events are not changed."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        try? Agent.service.unregister()
        try? FileManager.default.removeItem(at: store.directory)
        let tccutil = Process()
        tccutil.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        tccutil.arguments = ["reset", "Calendar", Bundle.main.bundleIdentifier ?? "com.corseapps.calendaralarm"]
        try? tccutil.run()
        tccutil.waitUntilExit()
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, error in
            DispatchQueue.main.async {
                if let error { NSAlert(error: error).runModal() }
                NSApp.terminate(nil)
            }
        }
    }

    @objc private func calendarToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if sender.state == .on { config.disabledCalendarIDs.remove(id) } else { config.disabledCalendarIDs.insert(id) }
        saveConfig()
    }

    @objc private func ringNow() {
        let now = Date()
        AlarmPresenter.present([Alarm(occurrence: .test(at: now.addingTimeInterval(300)), fireAt: now, ledgerKeys: [])])
    }

    @objc private func testBackground() {
        let fireAt = Date().addingTimeInterval(60)
        try? store.updateState { $0.testAlarms.append(fireAt) }
        statusLabel.stringValue = "Test alarm scheduled for \(fireAt.formatted(date: .omitted, time: .standard)). You can quit this window; the background check will ring it."
    }
}

/// Top-aligned document view for the calendar list.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
