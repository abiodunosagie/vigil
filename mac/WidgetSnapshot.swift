import Foundation

/// What the desktop widget shows, written by the app to a small JSON file the sandboxed
/// widget may read (a read-only exception for Vigil's own folder). Shared by both targets.
struct WidgetSnapshot: Codable, Equatable {
    struct Item: Codable, Equatable {
        let project: String
        let activity: Activity
    }

    var holding: Bool
    var phase: String
    var holdingSince: Date?
    var active: Int
    var sessions: [Item]
    var todayTasks: Int
    var todayWorking: TimeInterval
    /// When the app wrote this; it rewrites at least every `WidgetPublisher.heartbeat`.
    var updatedAt: Date
    /// Written by the app as it quits.
    var stopped = false

    /// Older than this, the app is not running (it crashed or was killed).
    static let maxAge: TimeInterval = 15 * 60

    func isCurrent(at now: Date = Date()) -> Bool {
        !stopped && now.timeIntervalSince(updatedAt) < Self.maxAge
    }

    /// Equal apart from when it was written.
    func sameContent(as other: WidgetSnapshot) -> Bool {
        var copy = other
        copy.updatedAt = updatedAt
        return copy == self
    }

    static let placeholder = WidgetSnapshot(holding: true, phase: "Claude on a task", holdingSince: Date(), active: 1,
                                            sessions: [Item(project: "vigil", activity: .working)],
                                            todayTasks: 3, todayWorking: 2700, updatedAt: Date())

    /// The real home folder: inside the widget's sandbox, NSHomeDirectory points at its container.
    static var url: URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir }.map { String(cString: $0) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Vigil/widget.json")
    }

    func write() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }

    static func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
}
