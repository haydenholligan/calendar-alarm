import AppKit
import CalendarAlarmCore

/// Shows due alarms one at a time in a full-screen window with a looping sound.
@MainActor
final class AlarmPresenter: NSObject {
    private var queue: [Alarm]
    /// nil for ad-hoc rings from Settings: nothing is recorded.
    private let store: Store?
    private let onFinish: @MainActor () -> Void
    private var window: AlarmWindow?
    private var sound: NSSound?
    private var tick: Timer?
    private var current: Alarm?

    private static var active: AlarmPresenter?

    init(alarms: [Alarm], store: Store?, onFinish: @escaping @MainActor () -> Void) {
        queue = alarms
        self.store = store
        self.onFinish = onFinish
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    /// Run from `--sync`: start AppKit, ring, keep checking for alarms that came
    /// due meanwhile, and exit the process when nothing is left.
    static func runApp(alarms: [Alarm], store: Store?) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let presenter = AlarmPresenter(alarms: alarms, store: store) { exit(0) }
        active = presenter
        presenter.showNext()
        app.run()
        exit(0)
    }

    /// Ring inside an already-running app (Settings' "Ring now").
    static func present(_ alarms: [Alarm]) {
        let presenter = AlarmPresenter(alarms: alarms, store: nil) { active = nil }
        active = presenter
        presenter.showNext()
    }

    private func showNext() {
        if queue.isEmpty, let store {
            // Alarms may have come due while this one was ringing.
            switch Sync.nextAction(store: store) {
            case .ring(let alarms):
                queue = alarms
            case .wait(let until):
                stopRinging()
                Timer.scheduledTimer(withTimeInterval: max(0, until.timeIntervalSinceNow), repeats: false) { _ in
                    MainActor.assumeIsolated { self.showNext() }
                }
                return
            case .idle:
                break
            }
        }
        guard !queue.isEmpty else {
            stopRinging()
            onFinish()
            return
        }
        let alarm = queue.removeFirst()
        current = alarm
        let window = self.window ?? AlarmWindow(presenter: self, fullScreen: Store.standard.loadConfig().fullScreen)
        self.window = window
        window.show(alarm, remaining: queue.count)
        startRinging()
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.window?.updateCountdown() }
        }
    }

    private func startRinging() {
        if sound == nil {
            let url = Bundle.main.url(forResource: "alarm", withExtension: "wav")
            sound = url.flatMap { NSSound(contentsOf: $0, byReference: true) } ?? NSSound(named: "Glass")
            sound?.loops = true
        }
        if sound?.isPlaying == false { sound?.play() }
    }

    private func stopRinging() {
        sound?.stop()
        tick?.invalidate()
        tick = nil
        window?.orderOut(nil)
        window = nil
        current = nil
    }

    /// The Mac slept with an alarm up, or the alarm started during a lid-closed
    /// maintenance wake. Alarms now past the grace window are skipped, like any
    /// other alarm missed while asleep, instead of greeting the user late.
    @objc private func didWake() {
        let now = Date()
        let config = Store.standard.loadConfig()
        let missed = ([current].compactMap { $0 } + queue).filter { Planner.isMissed($0, now: now, config: config) }
        guard !missed.isEmpty else { return }
        try? store?.updateState { state in
            for alarm in missed { state.dismiss(alarm, at: now) }
        }
        queue.removeAll { Planner.isMissed($0, now: now, config: config) }
        if let current, Planner.isMissed(current, now: now, config: config) { showNext() }
    }

    // MARK: Actions

    func dismiss() {
        guard let alarm = current else { return }
        try? store?.updateState { $0.dismiss(alarm, at: Date()) }
        showNext()
    }

    func snooze(minutes: Int) {
        guard let alarm = current else { return }
        try? store?.updateState { $0.snooze(alarm, minutes: minutes, now: Date()) }
        showNext()
    }

    func join() {
        guard let url = current?.occurrence.joinURL else { return }
        NSWorkspace.shared.open(url)
        dismiss()
    }
}

/// Borderless window above full-screen apps: either covering the primary
/// display, or a compact floating panel near the top of it.
@MainActor
final class AlarmWindow: NSWindow {
    private unowned let presenter: AlarmPresenter
    private let fullScreen: Bool
    private let stack = NSStackView()
    private let statusLabel = AlarmWindow.label(size: 22, weight: .medium)
    private let titleLabel = AlarmWindow.label(size: 56, weight: .bold)
    private let detailLabel = AlarmWindow.label(size: 22, weight: .regular)
    private let queueLabel = AlarmWindow.label(size: 16, weight: .regular)
    private let joinButton = NSButton(title: "Join", target: nil, action: nil)
    private var start = Date()
    /// Keys are ignored briefly after each alarm appears: the window takes focus,
    /// and a Return or "j" typed for another app must not dismiss or join unseen.
    private var keysAllowedAt = Date.distantFuture

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(presenter: AlarmPresenter, fullScreen: Bool) {
        self.presenter = presenter
        self.fullScreen = fullScreen
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // The backdrop is dark regardless of system appearance, so controls must draw for dark too.
        appearance = NSAppearance(named: .darkAqua)
        isOpaque = false
        let backdrop = NSColor(calibratedWhite: 0.06, alpha: fullScreen ? 0.94 : 0.97)
        backgroundColor = fullScreen ? backdrop : .clear
        hasShadow = !fullScreen

        let scale: CGFloat = fullScreen ? 1 : 0.6
        statusLabel.font = .systemFont(ofSize: 22 * scale, weight: .medium)
        titleLabel.font = .systemFont(ofSize: 56 * scale, weight: .bold)
        detailLabel.font = .systemFont(ofSize: 22 * scale, weight: .regular)
        queueLabel.font = .systemFont(ofSize: 16 * max(scale, 0.8), weight: .regular)
        titleLabel.preferredMaxLayoutWidth = fullScreen ? 1200 : 520

        let snoozeButtons = [1, 5, 10].map { minutes in
            let b = NSButton(title: "Snooze \(minutes) min", target: self, action: #selector(snoozeClicked(_:)))
            b.tag = minutes
            return b
        }
        let dismissButton = NSButton(title: "Dismiss", target: self, action: #selector(dismissClicked))
        dismissButton.keyEquivalent = "\r"
        joinButton.target = self
        joinButton.action = #selector(joinClicked)
        joinButton.keyEquivalent = "j"
        joinButton.keyEquivalentModifierMask = []
        for b in snoozeButtons + [dismissButton, joinButton] {
            b.bezelStyle = .rounded
            b.controlSize = .large
            b.font = .systemFont(ofSize: fullScreen ? 18 : 14, weight: .medium)
        }
        joinButton.bezelColor = .systemBlue
        dismissButton.bezelColor = .systemRed

        let buttons = NSStackView(views: [joinButton] + snoozeButtons + [dismissButton])
        buttons.spacing = fullScreen ? 16 : 10
        for view in [statusLabel, titleLabel, detailLabel, buttons, queueLabel] { stack.addArrangedSubview(view) }
        stack.orientation = .vertical
        stack.spacing = fullScreen ? 24 : 12
        stack.setCustomSpacing(fullScreen ? 48 : 24, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        if !fullScreen {
            content.wantsLayer = true
            content.layer?.backgroundColor = backdrop.cgColor
            content.layer?.cornerRadius = 18
            content.layer?.masksToBounds = true
        }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: fullScreen ? -96 : -48),
        ])
        contentView = content

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitToScreen() }
        }
    }

    static func label(size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: "")
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = .white
        l.alignment = .center
        l.maximumNumberOfLines = 3
        return l
    }

    func show(_ alarm: Alarm, remaining: Int) {
        let o = alarm.occurrence
        start = o.start
        titleLabel.stringValue = o.title
        let time = o.start.formatted(date: .omitted, time: .shortened)
        detailLabel.stringValue = o.calendarTitle.isEmpty ? time : "\(time) · \(o.calendarTitle)"
        queueLabel.stringValue = remaining > 0 ? "\(remaining) more alarm\(remaining == 1 ? "" : "s") after this" : ""
        joinButton.isHidden = o.joinURL == nil
        updateCountdown()
        fitToScreen()
        keysAllowedAt = Date().addingTimeInterval(1)
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateCountdown() {
        let seconds = Int(start.timeIntervalSinceNow.rounded())
        let minutes = abs(seconds) / 60
        if seconds > 59 {
            statusLabel.stringValue = "Starts in \(minutes) min"
        } else if seconds >= 0 {
            statusLabel.stringValue = "Starting now"
        } else {
            statusLabel.stringValue = minutes == 0 ? "Started just now" : "Started \(minutes) min ago"
        }
    }

    private func fitToScreen() {
        guard let screen = NSScreen.screens.first else { return }
        if fullScreen {
            setFrame(screen.frame, display: true)
            return
        }
        let fitting = stack.fittingSize
        let size = NSSize(width: max(480, fitting.width + 48), height: fitting.height + 48)
        let area = screen.visibleFrame
        let origin = NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - area.height * 0.12)
        setFrame(NSRect(origin: origin, size: size), display: true)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        Date() < keysAllowedAt ? true : super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if Date() >= keysAllowedAt { presenter.dismiss() }
    }
    @objc private func dismissClicked() { presenter.dismiss() }
    @objc private func joinClicked() { presenter.join() }
    @objc private func snoozeClicked(_ sender: NSButton) { presenter.snooze(minutes: sender.tag) }
}
