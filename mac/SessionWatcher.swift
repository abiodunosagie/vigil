import Combine
import Foundation

/// Ties Vigil together: each tick it reads the sessions (MarkerScanner), turns changes into
/// notifications and log entries (Announcer, DailyLog), holds or releases the Mac (SleepGuard,
/// LidHelper, battery guard, manual hold) and updates the widget (WidgetPublisher).
///
/// A session holds the Mac while its marker says "busy" or "waiting", the marker is recent,
/// and its `claude` process is alive, or while a command Claude started is still running
/// after its turn. After the last one stops, the Mac is held a little longer (the grace time
/// in Settings): a Stop hook can send Claude straight back to work, and that should not let
/// the Mac doze off. Then the hold is released and macOS sleeps on its own settings.
@MainActor
final class SessionWatcher: ObservableObject {
    enum Phase: Equatable {
        /// No Claude session is on a task.
        case idle
        /// At least one session is working, waiting on the user, or running a command.
        case working
        /// The last session just stopped; still held until the given time.
        case finishing(until: Date)
    }

    /// One open session for the panel.
    struct Row: Identifiable, Equatable {
        let id: String
        let project: String
        let activity: Activity
        let since: Date
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var rows: [Row] = []
    /// Whether Vigil is keeping the Mac awake right now, for any reason.
    @Published private(set) var isHolding = false
    /// When the current hold began, while it lasts.
    @Published private(set) var holdingSince: Date?
    /// The manual hold's end; `.distantFuture` until the user turns it off.
    @Published private(set) var manualUntil: Date?
    /// The battery guard let go of every hold.
    @Published private(set) var batteryBlocked = false
    @Published private(set) var today = DailyLog.Summary()
    /// Set when macOS refused the power assertion.
    @Published private(set) var problem: String?

    var activeCount: Int { rows.filter { $0.activity.isActive }.count }

    private static let interval: TimeInterval = 3
    private static var folder: URL { MarkerScanner.folder }

    let settings: VigilSettings
    private let systemGuard = SleepGuard.system()
    private let displayGuard = SleepGuard.display()
    private let notifier: Notifier
    private let log = DailyLog.standard
    private var announcer = Announcer()
    private var pids: [String: Int32] = [:]
    /// Uptime of the last poll that saw an active session. Uptime, not the wall clock, so a
    /// clock change cannot stretch or skip the grace period.
    private var lastActiveUptime: TimeInterval?
    private var timer: Timer?
    private var settingsWatch: AnyCancellable?
    private let widget = WidgetPublisher()
    private var batteryNoticeSent = false
    private var currentDay = ""

    init(settings: VigilSettings) {
        self.settings = settings
        notifier = Notifier(settings: settings)
    }

    func start() {
        // Only this user may read which projects are open.
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.folder.path)
        notifier.askPermission()
        notifier.onOpenSession = { [weak self] id in
            guard let pid = self?.pids[id] else { return }
            TerminalJump.show(pid: pid)
        }
        // A changed switch (screen on, lid, battery) takes effect at once, not on the next tick.
        // objectWillChange fires before the new value is stored, so refresh on the next pass.
        settingsWatch = settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        systemGuard.release()
        displayGuard.release()
        LidHelper.beat(false)
        // The widget must not go on showing a hold that ended with the app.
        widget.publishStopped()
    }

    // MARK: manual hold

    /// Holds the Mac for `duration`, or until turned off when nil.
    func holdManually(for duration: TimeInterval?) {
        manualUntil = duration.map { Date().addingTimeInterval($0) } ?? .distantFuture
        refresh()
    }

    func endManualHold() {
        manualUntil = nil
        refresh()
    }

    // MARK: refresh

    func refresh() {
        // A folder that cannot be listed says nothing about the sessions; try again next tick.
        // A missing one (deleted by hand) is recreated and then reads as empty.
        guard let scan = MarkerScanner.scan(trackBackground: settings.trackBackground) else {
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            return
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        let now = Date()
        pids = Dictionary(scan.sessions.compactMap { session in session.pid.map { (session.id, $0) } },
                          uniquingKeysWith: { first, _ in first })
        rollDayIfNeeded(now)
        for announcement in announcer.update(scan.sessions, unreadable: scan.unreadable, abandoned: scan.abandoned,
                                             uptime: uptime, now: now) {
            announce(announcement, now: now)
        }

        let next = nextPhase(active: scan.sessions.contains { $0.activity.isActive }, uptime: uptime)
        if case .finishing = phase, next == .idle {
            notifier.post(.allDone, title: Format.allDoneTitle, body: Format.allDoneBody(manualHold: manualUntil != nil))
        }
        if let until = manualUntil, until <= now { manualUntil = nil }

        // Assign only on change: every @Published write redraws the icon and the panel.
        Self.assign(makeRows(scan.sessions, now: now), to: &rows)
        Self.assign(next, to: &phase)
        apply()
        widget.publish(WidgetSnapshot(
            holding: isHolding, phase: WidgetPublisher.phaseText(phase, manual: manualUntil != nil, blocked: batteryBlocked),
            holdingSince: holdingSince, active: activeCount,
            sessions: rows.prefix(4).map { WidgetSnapshot.Item(project: $0.project, activity: $0.activity) },
            todayTasks: today.tasks, todayWorking: today.working, updatedAt: now))
    }

    /// After midnight "today" starts empty, and old log days are pruned once a day.
    private func rollDayIfNeeded(_ now: Date) {
        let day = DailyLog.dayName(now)
        guard day != currentDay else { return }
        currentDay = day
        log.prune(now: now)
        today = log.summary(day: now)
    }

    private func nextPhase(active: Bool, uptime: TimeInterval) -> Phase {
        if active {
            lastActiveUptime = uptime
            return .working
        }
        let grace = TimeInterval(settings.graceSeconds)
        if let last = lastActiveUptime, uptime - last < grace {
            // Keep the end time fixed through the grace period instead of recomputing it.
            if case .finishing = phase { return phase }
            return .finishing(until: Date().addingTimeInterval(grace - (uptime - last)))
        }
        lastActiveUptime = nil
        return .idle
    }

    /// Since times come from the announcer, which stamps them once per change, so an
    /// unchanged session gives an equal row and nothing is redrawn.
    private func makeRows(_ sessions: [Session], now: Date) -> [Row] {
        sessions.map { session in
            Row(id: session.id,
                project: session.project ?? announcer.project(session.id) ?? "Claude session",
                activity: session.activity,
                since: announcer.since(session.id) ?? now)
        }.sorted { ($0.activity.rank, $0.since, $0.id) < ($1.activity.rank, $1.since, $1.id) }
    }

    private func announce(_ announcement: Announcement, now: Date) {
        switch announcement {
        case let .finished(id, project, duration, tools):
            log.append(DailyLog.Entry(project: project ?? "Claude session", finishedAt: now, duration: duration, tools: tools))
            today = log.summary(day: now)
            notifier.post(.finished, title: Format.finishedTitle,
                          body: Format.finished(project: project, duration: duration, tools: tools), session: id)
        case let .waiting(id, project):
            notifier.post(.waiting, title: Format.waitingTitle, body: Format.waiting(project: project), session: id)
        }
    }

    // MARK: holding

    private func apply() {
        let wantsHold = phase != .idle || manualUntil != nil
        updateBatteryGuard(wantsHold: wantsHold)
        let hold = wantsHold && !batteryBlocked
        Self.assign(hold, to: &isHolding)
        guard hold else {
            systemGuard.release()
            displayGuard.release()
            LidHelper.beat(false)
            Self.assign(nil, to: &holdingSince)
            Self.assign(nil, to: &problem)
            return
        }
        let count = activeCount
        let reason = count > 0
            ? "Vigil: Claude Code is on a task (\(count) session\(count == 1 ? "" : "s"))"
            : phase != .idle ? "Vigil: Claude Code just finished" : "Vigil: manual hold"
        let held = systemGuard.hold(reason: reason)
        if settings.keepScreenOn { displayGuard.hold(reason: reason) } else { displayGuard.release() }
        LidHelper.beat(held && settings.lidClosed && LidHelper.isInstalled)
        if held {
            if holdingSince == nil { holdingSince = Date() }
            Self.assign(nil, to: &problem)
        } else {
            Self.assign(nil, to: &holdingSince)
            Self.assign("macOS refused to keep the Mac awake.", to: &problem)
        }
    }

    /// On battery below the floor, every hold is dropped. One notice per low battery stretch,
    /// sent the first time a hold is actually refused, even if the battery went low while idle.
    /// Plugging in or charging back above the floor lifts it.
    private func updateBatteryGuard(wantsHold: Bool) {
        guard settings.batteryGuard, let battery = Battery.read(), battery.onBattery,
              battery.percent < settings.batteryFloor else {
            Self.assign(false, to: &batteryBlocked)
            batteryNoticeSent = false
            return
        }
        Self.assign(true, to: &batteryBlocked)
        if wantsHold, !batteryNoticeSent {
            batteryNoticeSent = true
            notifier.post(.warning, title: Format.batteryTitle, body: Format.battery(percent: battery.percent))
        }
    }

    private static func assign<T: Equatable>(_ value: T, to target: inout T) {
        if target != value { target = value }
    }
}
