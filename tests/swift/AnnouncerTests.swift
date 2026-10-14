// Tests for Announcer. Run: tests/run-swift-tests.sh
import Foundation

var failures = 0
func check(_ condition: Bool, _ name: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL line \(line): \(name)")
    }
}

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func s(_ id: String, _ activity: Activity, _ project: String? = "app", at updated: TimeInterval = 0) -> Session {
    Session(id: id, project: project, activity: activity, updatedAt: t0.addingTimeInterval(updated))
}

/// One scan at `t` seconds, with wall clock and uptime moving together.
func step(_ a: inout Announcer, _ sessions: [Session], _ t: TimeInterval,
          unreadable: Set<String> = [], abandoned: Set<String> = []) -> [Announcement] {
    a.update(sessions, unreadable: unreadable, abandoned: abandoned, uptime: t, now: t0.addingTimeInterval(t))
}

@main
enum AnnouncerTests {
    static func main() {
        let settle = Announcer.settle

        do {
            // The first scan learns what is open; it never announces.
            var a = Announcer()
            check(step(&a, [s("1", .waiting), s("2", .idle)], 0).isEmpty, "first scan is silent")
        }
        do {
            // Work then idle: finished only after the settle time, and only once.
            var a = Announcer()
            _ = step(&a, [s("1", .idle)], 0)
            check(step(&a, [s("1", .working)], 3).isEmpty, "working is silent")
            check(step(&a, [s("1", .idle)], 6).isEmpty, "first idle is silent")
            check(step(&a, [s("1", .idle)], 6 + settle - 1).isEmpty, "not settled yet")
            check(step(&a, [s("1", .idle)], 6 + settle) == [.finished(project: "app")], "finished once settled")
            check(step(&a, [s("1", .idle)], 100).isEmpty, "finished only once")
            check(step(&a, [], 103).isEmpty, "closing after the announcement is silent")
        }
        do {
            // A blocked Stop: idle for a moment, back to work, no false finished.
            var a = Announcer()
            _ = step(&a, [s("1", .working)], 0)
            _ = step(&a, [s("1", .idle)], 3)
            check(step(&a, [s("1", .working)], 6).isEmpty, "back to work")
            check(step(&a, [s("1", .working)], 40).isEmpty, "no finished while working")
            _ = step(&a, [s("1", .idle)], 41)
            check(step(&a, [s("1", .idle)], 41 + settle) == [.finished(project: "app")], "finished after real stop")
        }
        do {
            // Each question is announced once; answering and then stopping is a finish.
            var a = Announcer()
            _ = step(&a, [s("1", .working)], 0)
            check(step(&a, [s("1", .waiting)], 3) == [.waiting(project: "app")], "waiting announced")
            check(step(&a, [s("1", .waiting)], 30).isEmpty, "waiting announced once")
            _ = step(&a, [s("1", .working)], 33)
            check(step(&a, [s("1", .waiting)], 36) == [.waiting(project: "app")], "second question announced")
            _ = step(&a, [s("1", .idle)], 40)
            check(step(&a, [s("1", .idle)], 40 + settle) == [.finished(project: "app")], "waiting then idle finishes")
        }
        do {
            // A one-shot session whose marker Claude Code removed after working.
            var a = Announcer()
            _ = step(&a, [], 0)
            _ = step(&a, [s("1", .working, "scratch")], 3)
            check(step(&a, [], 6) == [.finished(project: "scratch")], "ended after work")
        }
        do {
            // Killed or closed mid-task: abandoned, not finished.
            var a = Announcer()
            _ = step(&a, [s("1", .working)], 0)
            check(step(&a, [], 3, abandoned: ["1"]).isEmpty, "abandoned is silent")
        }
        do {
            // Closed while a question was open: not a finish.
            var a = Announcer()
            _ = step(&a, [s("1", .working)], 0)
            _ = step(&a, [s("1", .waiting)], 3)
            check(step(&a, [], 6).isEmpty, "closing while waiting is silent")
        }
        do {
            // Gone quiet for too long: no finished, now or later.
            var a = Announcer()
            _ = step(&a, [s("1", .working)], 0)
            check(step(&a, [s("1", .stale)], 3).isEmpty, "stale is silent")
            check(step(&a, [s("1", .stale)], 3 + settle).isEmpty, "stale stays silent")
            check(step(&a, [], 60).isEmpty, "stale then closed is silent")
        }
        do {
            // A very long tool call goes stale, then a real Stop: that is a finish.
            var a = Announcer()
            _ = step(&a, [s("1", .working)], 0)
            _ = step(&a, [s("1", .stale)], 3)
            _ = step(&a, [s("1", .idle)], 6)
            check(step(&a, [s("1", .idle)], 6 + settle) == [.finished(project: "app")], "stale then idle finishes")
        }
        do {
            // First seen quiet (after a Vigil restart), then a real Stop: that is a finish.
            var a = Announcer()
            _ = step(&a, [s("1", .stale)], 0)
            _ = step(&a, [s("1", .idle)], 3)
            check(step(&a, [s("1", .idle)], 3 + settle) == [.finished(project: "app")], "first seen stale then idle")
        }
        do {
            // Stale then back to work: owes a finish again.
            var a = Announcer()
            _ = step(&a, [s("1", .stale)], 0)
            _ = step(&a, [s("1", .working)], 3)
            check(step(&a, [], 6) == [.finished(project: "app")], "stale, working, ended")
        }
        do {
            // Abandoned after a finish was already announced, or while waiting: silent.
            var a = Announcer()
            _ = step(&a, [s("1", .working), s("2", .working)], 0)
            _ = step(&a, [s("1", .idle), s("2", .waiting)], 3)
            _ = step(&a, [s("1", .idle), s("2", .waiting)], 3 + settle)
            check(step(&a, [], 30, abandoned: ["1", "2"]).isEmpty, "abandoned after finish or while waiting")
        }
        do {
            // An unreadable marker for one scan changes nothing.
            var a = Announcer()
            _ = step(&a, [s("1", .working)], 0)
            check(step(&a, [], 3, unreadable: ["1"]).isEmpty, "unreadable is kept")
            check(step(&a, [s("1", .working)], 6).isEmpty, "back after unreadable")
            check(a.since("1") == t0, "since survives an unreadable scan")
        }
        do {
            // A session that appears already waiting is announced.
            var a = Announcer()
            _ = step(&a, [], 0)
            check(step(&a, [s("1", .waiting, nil)], 3) == [.waiting(project: nil)], "new waiting session")
        }
        do {
            // Sessions are tracked independently.
            var a = Announcer()
            _ = step(&a, [s("1", .working, "a"), s("2", .working, "b")], 0)
            _ = step(&a, [s("1", .idle, "a"), s("2", .working, "b")], 3)
            check(step(&a, [s("1", .idle, "a"), s("2", .working, "b")], 3 + settle) == [.finished(project: "a")],
                  "only the finished one")
        }
        do {
            // Since: first sight takes the marker time; a change takes the scan time; no change keeps it.
            var a = Announcer()
            _ = step(&a, [s("1", .working, at: -3600)], 0)
            check(a.since("1") == t0.addingTimeInterval(-3600), "first sight uses the marker time")
            _ = step(&a, [s("1", .working, at: 5)], 10)  // a fresh marker write, same activity
            check(a.since("1") == t0.addingTimeInterval(-3600), "unchanged keeps since")
            _ = step(&a, [s("1", .idle, at: 12)], 15)
            check(a.since("1") == t0.addingTimeInterval(15), "a change stamps the scan time")
            _ = step(&a, [s("1", .idle, nil as String?)], 18)
            check(a.project("1") == "app", "project remembered when the marker has none")
        }
        print(failures == 0 ? "Announcer tests passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
