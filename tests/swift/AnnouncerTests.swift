// Tests for Announcer. Run: tests/run-swift-tests.sh
import Foundation

var failures = 0
func check(_ condition: Bool, _ name: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL line \(line): \(name)")
    }
}

func s(_ id: String, _ activity: Activity, _ project: String? = "app") -> Session {
    Session(id: id, project: project, activity: activity)
}

@main
enum AnnouncerTests {
    static func main() {
        // First scan never announces, even a waiting session.
        do {
            var a = Announcer()
            check(a.update([s("1", .waiting), s("2", .idle)], uptime: 0).isEmpty, "first scan is silent")
        }
        // Work, then idle: finished only after the settle time.
        do {
            var a = Announcer()
            _ = a.update([s("1", .idle)], uptime: 0)
            check(a.update([s("1", .working)], uptime: 3).isEmpty, "working is silent")
            check(a.update([s("1", .idle)], uptime: 6).isEmpty, "first idle is silent")
            check(a.update([s("1", .idle)], uptime: 6 + Announcer.settle - 1).isEmpty, "not settled yet")
            check(a.update([s("1", .idle)], uptime: 6 + Announcer.settle) == [.finished(project: "app")], "finished once settled")
            check(a.update([s("1", .idle)], uptime: 100).isEmpty, "finished only once")
        }
        // A blocked Stop: idle for a moment, back to work, no false finished.
        do {
            var a = Announcer()
            _ = a.update([s("1", .working)], uptime: 0)
            _ = a.update([s("1", .idle)], uptime: 3)
            check(a.update([s("1", .working)], uptime: 6).isEmpty, "back to work")
            check(a.update([s("1", .working)], uptime: 40).isEmpty, "no finished while working")
            _ = a.update([s("1", .idle)], uptime: 41)
            check(a.update([s("1", .idle)], uptime: 41 + Announcer.settle) == [.finished(project: "app")], "finished after real stop")
        }
        // Waiting is announced on each entry; answering and finishing then announces finished.
        do {
            var a = Announcer()
            _ = a.update([s("1", .working)], uptime: 0)
            check(a.update([s("1", .waiting)], uptime: 3) == [.waiting(project: "app")], "waiting announced")
            check(a.update([s("1", .waiting)], uptime: 30).isEmpty, "waiting announced once")
            _ = a.update([s("1", .working)], uptime: 33)
            check(a.update([s("1", .waiting)], uptime: 36) == [.waiting(project: "app")], "second question announced")
        }
        // A one-shot session that vanishes after working counts as finished.
        do {
            var a = Announcer()
            _ = a.update([], uptime: 0)
            _ = a.update([s("1", .working, "scratch")], uptime: 3)
            check(a.update([], uptime: 6) == [.finished(project: "scratch")], "vanished after work")
        }
        // A session closed while idle and already announced, or while waiting, says nothing.
        do {
            var a = Announcer()
            _ = a.update([s("1", .idle), s("2", .working)], uptime: 0)
            _ = a.update([s("1", .idle), s("2", .waiting)], uptime: 3)
            check(a.update([], uptime: 6).isEmpty, "closing idle or waiting is silent")
        }
        // A new session seen after the first scan already waiting is announced.
        do {
            var a = Announcer()
            _ = a.update([], uptime: 0)
            check(a.update([s("1", .waiting, nil)], uptime: 3) == [.waiting(project: nil)], "new waiting session")
        }
        // Sessions are tracked independently.
        do {
            var a = Announcer()
            _ = a.update([s("1", .working, "a"), s("2", .working, "b")], uptime: 0)
            _ = a.update([s("1", .idle, "a"), s("2", .working, "b")], uptime: 3)
            check(a.update([s("1", .idle, "a"), s("2", .working, "b")], uptime: 3 + Announcer.settle) == [.finished(project: "a")],
                  "only the finished one")
        }
        print(failures == 0 ? "Announcer tests passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
