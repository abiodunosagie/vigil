import Combine
import Darwin
import Foundation

/// Reads the markers the Claude Code hook writes and decides whether to keep the Mac awake.
///
/// A session counts as working while its marker says "busy", the marker is recent, and its
/// `claude` process is alive. After the last one stops, the Mac is held a little longer: a
/// Stop hook can send Claude straight back to work, and that should not let the Mac doze off.
@MainActor
final class SessionWatcher: ObservableObject {
    enum Phase: Equatable {
        /// No Claude session is working; macOS sleeps on its own settings.
        case idle
        /// At least one session is working.
        case working
        /// The last session just stopped; still held until the given time.
        case finishing(until: Date)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var workingCount = 0
    @Published private(set) var openCount = 0
    /// When the current hold began, while it lasts.
    @Published private(set) var holdingSince: Date?
    /// Set when macOS refused the power assertion.
    @Published private(set) var problem: String?

    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Vigil/sessions", isDirectory: true)
    /// How long the Mac stays held after the last session stops.
    static let grace: TimeInterval = 60
    private static let interval: TimeInterval = 3

    private let guardian = SleepGuard()
    /// Uptime of the last poll that saw a working session. Uptime, not the wall clock, so a
    /// clock change cannot stretch or skip the grace period.
    private var lastWorkingUptime: TimeInterval?
    private var timer: Timer?

    func start() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
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
        let counts = Self.scan()
        let uptime = ProcessInfo.processInfo.systemUptime
        let next: Phase
        if counts.working > 0 {
            lastWorkingUptime = uptime
            next = .working
        } else if let last = lastWorkingUptime, uptime - last < Self.grace {
            // Keep the end time fixed through the grace period instead of recomputing it.
            if case .finishing = phase { next = phase } else {
                next = .finishing(until: Date().addingTimeInterval(Self.grace - (uptime - last)))
            }
        } else {
            lastWorkingUptime = nil
            next = .idle
        }
        // Assign only on change: every @Published write redraws the icon and the panel.
        if workingCount != counts.working { workingCount = counts.working }
        if openCount != counts.open { openCount = counts.open }
        if phase != next { phase = next }
        apply()
    }

    private func apply() {
        guard phase != .idle else {
            guardian.release()
            if holdingSince != nil { holdingSince = nil }
            if problem != nil { problem = nil }
            return
        }
        let reason = workingCount > 0
            ? "Vigil: Claude Code is working (\(workingCount) session\(workingCount == 1 ? "" : "s"))"
            : "Vigil: Claude Code just finished"
        if guardian.hold(reason: reason) {
            if holdingSince == nil { holdingSince = Date() }
            if problem != nil { problem = nil }
        } else {
            if holdingSince != nil { holdingSince = nil }
            let message = "macOS refused to keep the Mac awake."
            if problem != message { problem = message }
        }
    }

    /// Counts working and open sessions. Markers whose `claude` process is gone are deleted,
    /// and so are temp files a hook left behind when it was killed mid-write.
    private static func scan() -> (working: Int, open: Int) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        var working = 0
        var open = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            // Only plain files: a FIFO named like a marker would block the read.
            guard values?.isRegularFile == true else { continue }
            if file.lastPathComponent.hasPrefix(".tmp-") {
                if let modified = values?.contentModificationDate, Date().timeIntervalSince(modified) > 600 {
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
            open += 1
            if marker.isWorking() { working += 1 }
        }
        return (working, open)
    }
}

/// One session's marker, as written by hooks/vigil-hook.py.
struct Marker: Decodable {
    let state: String
    let claudePid: Int32
    let updatedAt: TimeInterval

    /// A busy marker not refreshed for this long is not trusted. Claude Code fires no hook
    /// when the user interrupts a turn, and every tool call refreshes the marker, while a
    /// foreground tool call is capped at 10 minutes.
    static let staleAfter: TimeInterval = 20 * 60

    enum CodingKeys: String, CodingKey {
        case state
        case claudePid = "claude_pid"
        case updatedAt = "updated_at"
    }

    static func read(_ url: URL) -> Marker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    func isWorking(now: Date = Date()) -> Bool {
        state == "busy" && now.timeIntervalSince1970 - updatedAt < Self.staleAfter
    }

    /// The owner still runs and is still Claude Code, so a reused pid cannot hold the Mac
    /// awake. Checked by executable path: Claude Code renames its process title to its
    /// version ("2.1.299"), so the process name says nothing. The native install runs
    /// `~/.local/share/claude/versions/<version>`; others run `claude` or `node`.
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
