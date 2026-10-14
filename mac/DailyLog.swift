import Foundation

/// One file per day of finished tasks: project, length, tool calls. Kept 30 days.
///
/// Lives in `Vigil/log/`, outside `sessions/`, whose every `.json` is treated as a marker.
struct DailyLog {
    struct Entry: Codable, Equatable {
        let project: String
        let finishedAt: Date
        let duration: TimeInterval?
        let tools: Int?
    }

    struct Summary: Equatable {
        var tasks = 0
        var working: TimeInterval = 0
        var longest: Entry?
    }

    static let keepDays = 30
    let folder: URL

    static let standard = DailyLog(folder: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Vigil/log", isDirectory: true))

    func append(_ entry: Entry) {
        var entries = read(day: entry.finishedAt)
        entries.append(entry)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(entries) {
            try? data.write(to: file(for: entry.finishedAt), options: [.atomic])
        }
    }

    func read(day: Date) -> [Entry] {
        guard let data = try? Data(contentsOf: file(for: day)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    func summary(day: Date = Date()) -> Summary {
        Self.summarize(read(day: day))
    }

    static func summarize(_ entries: [Entry]) -> Summary {
        var summary = Summary()
        for entry in entries {
            summary.tasks += 1
            summary.working += entry.duration ?? 0
            if (entry.duration ?? 0) > (summary.longest?.duration ?? -1) { summary.longest = entry }
        }
        return summary
    }

    /// Deletes day files older than `keepDays`.
    func prune(now: Date = Date()) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let cutoff = Self.dayName(Calendar.current.date(byAdding: .day, value: -Self.keepDays, to: now) ?? now)
        for file in files where file.pathExtension == "json" {
            let name = file.deletingPathExtension().lastPathComponent
            // Day names sort like dates, so a plain string comparison finds the old ones.
            if name.count == 10, name < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func file(for day: Date) -> URL {
        folder.appendingPathComponent(Self.dayName(day) + ".json")
    }

    static func dayName(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
