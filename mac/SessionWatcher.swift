import Combine
import Darwin
import Foundation

/// Reads the markers the Claude Code hook writes, keeps the Mac awake while any session is
/// on a task, and tells the user when sessions finish or need them.
///
/// A session holds the Mac while its marker says "busy" or "waiting", the marker is recent,
/// and its `claude` process is alive. After the last one stops, the Mac is held a little
/// longer: a Stop hook can send Claude straight back to work, and that should not let the Mac
/// doze off. Then the hold is released and macOS sleeps on its own settings.
@MainActor
final class SessionWatcher: ObservableObject {
    enum Phase: Equatable {
        /// No Claude session is on a task; macOS sleeps on its own settings.
        case idle
        /// At least one session is working or waiting on the user.
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
    /// When the current hold began, while it lasts.
    @Published private(set) var holdingSince: Date?
    /// Set when macOS refused the power assertion.
    @Published private(set) var problem: String?

    var activeCount: Int { rows.filter { $0.activity != .idle }.count }

    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Vigil/sessions", isDirectory: true)
    /// How long the Mac stays held after the last session stops.
    static let grace: TimeInterval = 60
    private static let interval: TimeInterval = 3
    /// A hook killed mid-write leaves a temp file; this old, it is clearly abandoned.
    private static let abandonedTempAge: TimeInterval = 600

    private let guardian = SleepGuard()
    private let notifier = Notifier()
    private var announcer = Announcer()
    /// Uptime of the last poll that saw an active session. Uptime, not the wall clock, so a
    /// clock change cannot stretch or skip the grace period.
    private var lastActiveUptime: TimeInterval?
    private var timer: Timer?

    func start() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        notifier.askPermission()
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
        guardian.release()
    }

    func refresh() {
        let sessions = Self.scan()
        let uptime = ProcessInfo.processInfo.systemUptime
        for announcement in announcer.update(sessions, uptime: uptime) { announce(announcement) }

        let active = sessions.contains { $0.activity != .idle }
        let next: Phase
        if active {
            lastActiveUptime = uptime
            next = .working
        } else if let last = lastActiveUptime, uptime - last < Self.grace {
            // Keep the end time fixed through the grace period instead of recomputing it.
            if case .finishing = phase { next = phase } else {
                next = .finishing(until: Date().addingTimeInterval(Self.grace - (uptime - last)))
            }
        } else {
            lastActiveUptime = nil
            next = .idle
        }
        if case .finishing = phase, next == .idle {
            notifier.post(title: "All Claude sessions are done",
                          body: "Vigil let go. Your Mac now sleeps on its normal settings.")
        }

        let now = Date()
        let nextRows = sessions.map { session in
            let since = announcer.tracks[session.id].map { now.addingTimeInterval($0.since - uptime) } ?? now
            return Row(id: session.id, project: session.project ?? "Claude session", activity: session.activity, since: since)
        }.sorted { ($0.activity.rank, $0.since) < ($1.activity.rank, $1.since) }
        // Assign only on change: every @Published write redraws the icon and the panel.
        Self.assign(nextRows, to: &rows)
        Self.assign(next, to: &phase)
        apply()
    }

    private func announce(_ announcement: Announcement) {
        switch announcement {
        case .finished(let project):
            notifier.post(title: "Claude finished", body: project.map { "Done in \($0)." } ?? "A session is done.")
        case .waiting(let project):
            notifier.post(title: "Claude needs you", body: project.map { "Waiting for your answer in \($0)." } ?? "A session is waiting for your answer.")
        }
    }

    private func apply() {
        guard phase != .idle else {
            guardian.release()
            Self.assign(nil, to: &holdingSince)
            Self.assign(nil, to: &problem)
            return
        }
        let count = activeCount
        let reason = count > 0
            ? "Vigil: Claude Code is working (\(count) session\(count == 1 ? "" : "s"))"
            : "Vigil: Claude Code just finished"
        if guardian.hold(reason: reason) {
            if holdingSince == nil { holdingSince = Date() }
            Self.assign(nil, to: &problem)
        } else {
            Self.assign(nil, to: &holdingSince)
            Self.assign("macOS refused to keep the Mac awake.", to: &problem)
        }
    }

    private static func assign<T: Equatable>(_ value: T, to target: inout T) {
        if target != value { target = value }
    }

    /// The live sessions. Markers whose `claude` process is gone are deleted, and so are temp
    /// files a hook left behind when it was killed mid-write.
    private static func scan() -> [Session] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        var sessions: [Session] = []
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
            guard file.pathExtension == "json", let marker = Marker.read(file) else { continue }
            guard marker.ownerAlive else {
                // Re-read first: a resumed session may have just rewritten this file.
                if Marker.read(file)?.ownerAlive == false { try? fm.removeItem(at: file) }
                continue
            }
            sessions.append(Session(id: file.deletingPathExtension().lastPathComponent,
                                    project: marker.project, activity: marker.activity()))
        }
        return sessions
    }
}

extension Activity {
    /// Panel order: working first, then waiting, then idle.
    var rank: Int {
        switch self {
        case .working: 0
        case .waiting: 1
        case .idle: 2
        }
    }
}

/// One session's marker, as written by hooks/vigil-hook.py.
struct Marker: Decodable {
    let state: String
    let claudePid: Int32
    let updatedAt: TimeInterval
    let project: String?

    /// A working or waiting marker not refreshed for this long is not trusted. Claude Code
    /// fires no hook when the user interrupts a turn, and a question left unanswered should
    /// not hold the Mac forever. Every tool call refreshes the marker.
    static let staleAfter: TimeInterval = 45 * 60

    enum CodingKeys: String, CodingKey {
        case state
        case claudePid = "claude_pid"
        case updatedAt = "updated_at"
        case project
    }

    static func read(_ url: URL) -> Marker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    func activity(now: Date = Date()) -> Activity {
        guard now.timeIntervalSince1970 - updatedAt < Self.staleAfter else { return .idle }
        switch state {
        case "busy": return .working
        case "waiting": return .waiting
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
