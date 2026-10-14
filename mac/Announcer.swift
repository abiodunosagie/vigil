import Foundation

/// What one Claude Code session is doing, as Vigil sees it.
enum Activity: Equatable {
    /// Running a task.
    case working
    /// Asked the user something mid-task (a permission prompt or a question).
    case waiting
    /// Finished, or sitting at the prompt.
    case idle
}

struct Session: Equatable {
    let id: String
    let project: String?
    let activity: Activity
}

/// Something worth a notification.
enum Announcement: Equatable {
    case finished(project: String?)
    case waiting(project: String?)
}

/// Turns successive scans of the sessions into notifications.
///
/// A session counts as finished once it has stayed idle for `settle` seconds after doing
/// work, not on the first idle: a Stop hook can send Claude straight back to work, and that
/// must not produce a false "finished". A session that disappears with work not yet
/// announced (a one-shot `claude -p` run ends in milliseconds) counts as finished too.
struct Announcer {
    struct Track {
        var activity: Activity
        /// Uptime of the last change of activity.
        var since: TimeInterval
        var project: String?
        /// Did work since the last "finished".
        var owesFinished: Bool
    }

    static let settle: TimeInterval = 20

    private(set) var tracks: [String: Track] = [:]
    /// The first scan only learns what is there; announcing then would repeat old news.
    private var seeded = false

    mutating func update(_ sessions: [Session], uptime: TimeInterval) -> [Announcement] {
        var out: [Announcement] = []
        var seen = Set<String>()
        for session in sessions {
            seen.insert(session.id)
            guard var track = tracks[session.id] else {
                tracks[session.id] = Track(activity: session.activity, since: uptime, project: session.project,
                                           owesFinished: session.activity != .idle)
                if seeded, session.activity == .waiting { out.append(.waiting(project: session.project)) }
                continue
            }
            if let project = session.project { track.project = project }
            if track.activity != session.activity {
                track.activity = session.activity
                track.since = uptime
                switch session.activity {
                case .working: track.owesFinished = true
                case .waiting:
                    track.owesFinished = true
                    out.append(.waiting(project: track.project))
                case .idle: break
                }
            }
            if track.activity == .idle, track.owesFinished, uptime - track.since >= Self.settle {
                track.owesFinished = false
                out.append(.finished(project: track.project))
            }
            tracks[session.id] = track
        }
        for (id, track) in tracks where !seen.contains(id) {
            if track.owesFinished, track.activity != .waiting { out.append(.finished(project: track.project)) }
            tracks[id] = nil
        }
        seeded = true
        return out
    }
}
