import Foundation

/// What the desktop widget shows, written by the app to a small JSON file the sandboxed
/// widget may read (a read-only exception for Vigil's own folder). Shared by both targets.
struct WidgetSnapshot: Codable, Equatable {
    struct Item: Codable, Equatable {
        let project: String
        let activity: String
    }

    var holding: Bool
    var phase: String
    var holdingSince: Date?
    var active: Int
    var sessions: [Item]
    var todayTasks: Int
    var todayWorking: TimeInterval

    static let placeholder = WidgetSnapshot(holding: true, phase: "Claude on a task", holdingSince: Date(), active: 1,
                                            sessions: [Item(project: "vigil", activity: "working")],
                                            todayTasks: 3, todayWorking: 2700)

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
