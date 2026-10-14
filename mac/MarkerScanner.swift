import Darwin
import Foundation

/// Reads the session markers the Claude Code hook writes.
enum MarkerScanner {
    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Vigil/sessions", isDirectory: true)
    /// A hook killed mid-write leaves a temp file; this old, it is clearly abandoned.
    private static let abandonedTempAge: TimeInterval = 600

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
    static func scan(trackBackground: Bool) -> Scan? {
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
