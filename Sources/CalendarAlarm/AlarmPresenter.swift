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
        let window = self.window ?? AlarmWindow(presenter: self)
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

    // MARK: Actions

    func dismiss() {
        guard let alarm = current else { return }
        try? store?.updateState { $0.dismiss(alarm) }
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

/// Borderless window covering the primary display, above full-screen apps.
@MainActor
final class AlarmWindow: NSWindow {
    private unowned let presenter: AlarmPresenter
    private let statusLabel = AlarmWindow.label(size: 22, weight: .medium)
    private let titleLabel = AlarmWindow.label(size: 56, weight: .bold)
    private let detailLabel = AlarmWindow.label(size: 22, weight: .regular)
    private let queueLabel = AlarmWindow.label(size: 16, weight: .regular)
    private let joinButton = NSButton(title: "Join", target: nil, action: nil)
    private var start = Date()

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(presenter: AlarmPresenter) {
        self.presenter = presenter
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // The backdrop is dark regardless of system appearance, so controls must draw for dark too.
        appearance = NSAppearance(named: .darkAqua)
        backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.94)
        isOpaque = false
        hasShadow = false

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
            b.font = .systemFont(ofSize: 18, weight: .medium)
        }
        joinButton.bezelColor = .systemBlue
        dismissButton.bezelColor = .systemRed

        let buttons = NSStackView(views: [joinButton] + snoozeButtons + [dismissButton])
        buttons.spacing = 16
        let stack = NSStackView(views: [statusLabel, titleLabel, detailLabel, buttons, queueLabel])
        stack.orientation = .vertical
        stack.spacing = 24
        stack.setCustomSpacing(48, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -96),
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
        if let screen = NSScreen.screens.first { setFrame(screen.frame, display: true) }
    }

    override func cancelOperation(_ sender: Any?) { presenter.dismiss() }
    @objc private func dismissClicked() { presenter.dismiss() }
    @objc private func joinClicked() { presenter.join() }
    @objc private func snoozeClicked(_ sender: NSButton) { presenter.snooze(minutes: sender.tag) }
}
