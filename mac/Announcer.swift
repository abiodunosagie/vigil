import Foundation

/// What one Claude Code session is doing, as Vigil sees it.
enum Activity: Equatable {
    /// Running a task.
    case working
    /// Asked the user something mid-task (a permission prompt or a question).
    case waiting
    /// Finished, or sitting at the prompt.
    case idle
    /// Said working or waiting, but has not been heard from for too long (an interrupted
    /// turn, a question left unanswered, a very long tool call). Not held awake. Reported as
    /// finished only if a real Stop later turns it idle.
    case stale

    /// Holds the Mac awake.
    var isActive: Bool { self == .working || self == .waiting }

    /// Panel order: working first, then waiting, then the rest.
    var rank: Int {
        switch self {
        case .working: 0
        case .waiting: 1
        case .idle: 2
        case .stale: 3
        }
    }
}

struct Session: Equatable {
    let id: String
    let project: String?
    let activity: Activity
    /// When the hook last wrote this session's marker.
    let updatedAt: Date
}

/// Something worth a notification.
enum Announcement: Equatable {
    case finished(project: String?)
    case waiting(project: String?)
}

/// Turns successive scans of the sessions into notifications, and remembers since when each
/// session has been doing what it does.
///
/// A session counts as finished once it has stayed idle for `settle` seconds after doing
/// work, not on the first idle: a Stop hook can send Claude straight back to work, and that
/// must not produce a false "finished". A session whose marker was removed by Claude Code
/// (a one-shot `claude -p` run ends in milliseconds) after working counts as finished too;
/// one whose process died (a closed terminal, a kill), or that ends while waiting or stale,
/// does not.
struct Announcer {
    struct Track {
        var activity: Activity
        /// Uptime of the last change of activity, for the settle time.
        var changedAtUptime: TimeInterval
        /// Wall clock time of the last change of activity, for the panel.
        var changedAt: Date
        var project: String?
        /// Did work since the last "finished".
        var owesFinished: Bool
    }

    static let settle: TimeInterval = 20

    private var tracks: [String: Track] = [:]
    /// The first scan only learns what is there; announcing then would repeat old news.
    private var seeded = false

    /// Since when the session has been in its current activity.
    func since(_ id: String) -> Date? { tracks[id]?.changedAt }

    /// The last project name heard for the session.
    func project(_ id: String) -> String? { tracks[id]?.project }

    /// - Parameters:
    ///   - unreadable: sessions whose marker could not be read this time; kept as they were.
    ///   - abandoned: sessions whose `claude` process died; dropped without a "finished".
    ///   - uptime: system uptime, for the settle time.
    ///   - now: wall clock time, for since times.
    mutating func update(_ sessions: [Session], unreadable: Set<String> = [], abandoned: Set<String> = [],
                         uptime: TimeInterval, now: Date) -> [Announcement] {
        var out: [Announcement] = []
        var seen = unreadable
        for session in sessions {
            seen.insert(session.id)
            guard var track = tracks[session.id] else {
                // First sight: the marker's own time is the best guess of when this began.
                tracks[session.id] = Track(activity: session.activity, changedAtUptime: uptime,
                                           changedAt: min(session.updatedAt, now), project: session.project,
                                           owesFinished: session.activity != .idle)
                if seeded, session.activity == .waiting { out.append(.waiting(project: session.project)) }
                continue
            }
            if let project = session.project { track.project = project }
            if track.activity != session.activity {
                track.activity = session.activity
                track.changedAtUptime = uptime
                track.changedAt = now
                switch session.activity {
                case .working: track.owesFinished = true
                case .waiting:
                    track.owesFinished = true
                    out.append(.waiting(project: track.project))
                case .idle, .stale: break
                }
            }
            if track.activity == .idle, track.owesFinished, uptime - track.changedAtUptime >= Self.settle {
                track.owesFinished = false
                out.append(.finished(project: track.project))
            }
            tracks[session.id] = track
        }
        for (id, track) in tracks where !seen.contains(id) {
            let ended = !abandoned.contains(id) && track.owesFinished
                && track.activity != .waiting && track.activity != .stale
            if ended { out.append(.finished(project: track.project)) }
            tracks[id] = nil
        }
        seeded = true
        return out
    }
}
