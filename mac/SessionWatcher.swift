import Combine
import Foundation

/// Reads the markers the Claude Code hook writes and decides whether to keep the Mac awake.
///
/// A session counts as working while its marker says "busy" and its `claude` process is
/// alive. After the last one stops, the Mac is held a little longer: a Stop hook can send
/// Claude straight back to work, and that should not let the Mac doze off in between.
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
    private var lastWorking: Date?
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

    func refresh(now: Date = Date()) {
        let (working, open) = Self.scan()
        workingCount = working
        openCount = open

        if working > 0 {
            lastWorking = now
            phase = .working
        } else if let last = lastWorking, now.timeIntervalSince(last) < Self.grace {
            phase = .finishing(until: last.addingTimeInterval(Self.grace))
        } else {
            lastWorking = nil
            phase = .idle
        }
        apply()
    }

    private func apply() {
        guard phase != .idle else {
            guardian.release()
            holdingSince = nil
            problem = nil
            return
        }
        let reason = workingCount > 0
            ? "Vigil: Claude Code is working (\(workingCount) session\(workingCount == 1 ? "" : "s"))"
            : "Vigil: Claude Code just finished"
        if guardian.hold(reason: reason) {
            if holdingSince == nil { holdingSince = Date() }
            problem = nil
        } else {
            holdingSince = nil
            problem = "macOS refused to keep the Mac awake."
        }
    }

    /// (working sessions, live sessions). Markers whose `claude` process is gone are deleted.
    private static func scan() -> (Int, Int) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var working = 0
        var open = 0
        for file in files where file.pathExtension == "json" {
            guard let marker = Marker.read(file) else { continue }
            guard marker.ownerAlive else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            open += 1
            if marker.state == "busy" { working += 1 }
        }
        return (working, open)
    }
}

/// One session's marker, as written by hooks/vigil-hook.py.
struct Marker: Decodable {
    let state: String
    let claudePid: Int32

    enum CodingKeys: String, CodingKey {
        case state
        case claudePid = "claude_pid"
    }

    static func read(_ url: URL) -> Marker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    /// kill with signal 0 only checks: EPERM still means the process exists.
    var ownerAlive: Bool {
        guard claudePid > 1 else { return false }
        return kill(claudePid, 0) == 0 || errno == EPERM
    }
}
