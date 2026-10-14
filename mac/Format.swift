import Foundation

/// Text for notifications, the panel and the log.
enum Format {
    /// "Done in vigil, 14 min, 38 commands."
    static func finished(project: String?, duration: TimeInterval?, tools: Int?) -> String {
        var parts = [project.map { "Done in \($0)" } ?? "A session is done"]
        if let duration { parts.append(length(duration)) }
        if let tools { parts.append(tools == 1 ? "1 command" : "\(tools) commands") }
        return parts.joined(separator: ", ") + "."
    }

    /// "45 s", "14 min", "2 h 5 min".
    static func length(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
