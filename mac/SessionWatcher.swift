import Combine
import Darwin
import Foundation
import WidgetKit

/// Reads the markers the Claude Code hook writes, keeps the Mac awake while any session is
/// on a task (or the user asked for a manual hold), and tells the user when sessions finish
/// or need them.
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

    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Vigil/sessions", isDirectory: true)
    private static let interval: TimeInterval = 3
    /// A hook killed mid-write leaves a temp file; this old, it is clearly abandoned.
    private static let abandonedTempAge: TimeInterval = 600

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
    private var lastWidget: WidgetSnapshot?

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
        log.prune()
        today = log.summary()
        // A changed switch (screen on, lid, battery) takes effect at once, not on the next tick.
        settingsWatch = settings.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
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
        guard let scan = Self.scan(trackBackground: settings.trackBackground) else {
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            return
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        let now = Date()
        pids = Dictionary(scan.sessions.compactMap { session in session.pid.map { (session.id, $0) } },
                          uniquingKeysWith: { first, _ in first })
        for announcement in announcer.update(scan.sessions, unreadable: scan.unreadable, abandoned: scan.abandoned,
                                             uptime: uptime, now: now) {
            announce(announcement, sessions: scan.sessions, now: now)
        }

        let next = nextPhase(active: scan.sessions.contains { $0.activity.isActive }, uptime: uptime)
        if case .finishing = phase, next == .idle {
            notifier.post(.allDone, title: "All Claude sessions are done",
                          body: manualUntil == nil
                              ? "Vigil let go. Your Mac now sleeps on its normal settings."
                              : "Your manual hold still keeps the Mac awake.")
        }
        if let until = manualUntil, until <= now { manualUntil = nil }

        // Assign only on change: every @Published write redraws the icon and the panel.
        Self.assign(makeRows(scan.sessions, now: now), to: &rows)
        Self.assign(next, to: &phase)
        apply()
        writeWidget()
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

    private func announce(_ announcement: Announcement, sessions: [Session], now: Date) {
        switch announcement {
        case let .finished(project, duration, tools):
            log.append(DailyLog.Entry(project: project ?? "Claude session", finishedAt: now, duration: duration, tools: tools))
            today = log.summary()
            let id = sessions.first { $0.project == project }?.id
            notifier.post(.finished, title: "Claude finished",
                          body: Format.finished(project: project, duration: duration, tools: tools), session: id)
        case .waiting(let project):
            let id = sessions.first { $0.project == project && $0.activity == .waiting }?.id
            notifier.post(.waiting, title: "Claude needs you",
                          body: project.map { "Waiting for your answer in \($0)." } ?? "A session is waiting for your answer.",
                          session: id)
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

    /// On battery below the floor, every hold is dropped once, with one notice. Plugging in
    /// or charging back above the floor lifts it.
    private func updateBatteryGuard(wantsHold: Bool) {
        guard settings.batteryGuard, let battery = Battery.read(), battery.onBattery,
              battery.percent < settings.batteryFloor else {
            Self.assign(false, to: &batteryBlocked)
            return
        }
        if !batteryBlocked, wantsHold {
            notifier.post(.warning, title: "Battery low, Vigil let go",
                          body: "At \(battery.percent)% on battery the Mac sleeps normally again. Plug in to keep it awake.")
        }
        Self.assign(true, to: &batteryBlocked)
    }

    private static func assign<T: Equatable>(_ value: T, to target: inout T) {
        if target != value { target = value }
    }

    // MARK: widget

    private func writeWidget() {
        let snapshot = WidgetSnapshot(
            holding: isHolding, phase: Self.widgetPhase(phase, manual: manualUntil != nil, blocked: batteryBlocked),
            holdingSince: holdingSince, active: activeCount,
            sessions: rows.prefix(4).map { WidgetSnapshot.Item(project: $0.project, activity: Self.activityLabel($0.activity)) },
            todayTasks: today.tasks, todayWorking: today.working)
        guard snapshot != lastWidget else { return }
        lastWidget = snapshot
        snapshot.write()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func widgetPhase(_ phase: Phase, manual: Bool, blocked: Bool) -> String {
        if blocked { return "Battery low" }
        switch phase {
        case .working: return "Claude on a task"
        case .finishing: return "Just finished"
        case .idle: return manual ? "Manual hold" : "Mac can sleep"
        }
    }

    static func activityLabel(_ activity: Activity) -> String {
        switch activity {
        case .working: "working"
        case .waiting: "needs you"
        case .background: "running a command"
        case .idle: "idle"
        case .stale: "quiet"
        }
    }

    struct Scan {
        var sessions: [Session] = []
        /// Markers present but unreadable this time (mid-write, or corrupt).
        var unreadable: Set<String> = []
        /// Markers deleted because their `claude` process died.
        var abandoned: Set<String> = []
    }

    /// The live sessions, or nil when the folder cannot be listed. Markers whose `claude`
    /// process is gone are deleted and reported as abandoned. Temp files a hook left behind
    /// when it was killed mid-write, and markers unreadable for longer than the stale limit,
    /// are deleted too.
    private static func scan(trackBackground: Bool) -> Scan? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return nil }
        var result = Scan()
        for file in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            // Only plain files: a FIFO named like a marker would block the read.
            guard values?.isRegularFile == true else { continue }
            if file.lastPathComponent.hasPrefix(".tmp-") {
                if let modified = values?.contentModificationDate, Date().timeIntervalSince(modified) > abandonedTempAge {
                    try? fm.removeItem(at: file)
                }
                continue
            }
            guard file.pathExtension == "json" else { continue }
            let id = file.deletingPathExtension().lastPathComponent
            let age = values?.contentModificationDate.map { Date().timeIntervalSince($0) } ?? 0
            guard var marker = Marker.read(file) else {
                if age > Marker.staleAfter {
                    // Dropped without a "finished": nothing says the work ended.
                    try? fm.removeItem(at: file)
                    result.abandoned.insert(id)
                } else {
                    result.unreadable.insert(id)
                }
                continue
            }
            if !marker.ownerAlive {
                // Re-read first: a resumed session may have just rewritten this file.
                guard let again = Marker.read(file) else {
                    result.unreadable.insert(id)
                    continue
                }
                guard again.ownerAlive else {
                    try? fm.removeItem(at: file)
                    result.abandoned.insert(id)
                    continue
                }
                marker = again
            }
            var activity = marker.activity()
            // Claude's turn is over (or has gone quiet) but a command it started still runs.
            if trackBackground, activity == .idle || activity == .stale,
               ProcessTree.runningCommands(of: marker.claudePid) > 0 {
                activity = .background
            }
            result.sessions.append(Session(id: id, project: marker.project, activity: activity,
                                           updatedAt: Date(timeIntervalSince1970: marker.updatedAt),
                                           turnStarted: marker.turnStarted.map { Date(timeIntervalSince1970: $0) },
                                           tools: marker.tools, pid: marker.claudePid))
        }
        return result
    }
}

/// One session's marker, as written by hooks/vigil-hook.py.
struct Marker: Decodable {
    let state: String
    let claudePid: Int32
    let updatedAt: TimeInterval
    let project: String?
    let turnStarted: TimeInterval?
    let tools: Int?

    /// A working or waiting marker not refreshed for this long is not trusted. Claude Code
    /// fires no hook when the user interrupts a turn, and a question left unanswered should
    /// not hold the Mac forever. Every tool call refreshes the marker.
    static let staleAfter: TimeInterval = 45 * 60

    enum CodingKeys: String, CodingKey {
        case state
        case claudePid = "claude_pid"
        case updatedAt = "updated_at"
        case project
        case turnStarted = "turn_started"
        case tools
    }

    /// Real markers are about 120 bytes; anything far bigger is not one.
    private static let maxSize = 4096

    static func read(_ url: URL) -> Marker? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxSize + 1), data.count <= maxSize else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    func activity(now: Date = Date()) -> Activity {
        let fresh = now.timeIntervalSince1970 - updatedAt < Self.staleAfter
        switch state {
        case "busy": return fresh ? .working : .stale
        case "waiting": return fresh ? .waiting : .stale
        default: return .idle
        }
    }

    /// The owner still runs and looks like Claude Code, which makes a reused pid unlikely to
    /// matter (a reused pid that happens to be another Node process still passes, for at most
    /// `staleAfter`). Checked by executable path: Claude Code renames its process title to its
    /// version ("2.1.299"), so the process name says nothing. The native install runs
    /// `~/.local/share/claude/versions/<version>`; npm installs run `node`.
    var ownerAlive: Bool {
        guard claudePid > 1 else { return false }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(claudePid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return Self.isClaudeExecutable(String(cString: buffer))
    }

    static func isClaudeExecutable(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == "claude" || name == "node" || path.contains("/claude/versions/") || path.contains("claude-code")
    }
}
