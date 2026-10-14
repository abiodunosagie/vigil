import Foundation

/// Text for notifications, the panel, the widget and the log.
enum Format {
    static let finishedTitle = "Claude finished"
    static let waitingTitle = "Claude needs you"
    static let allDoneTitle = "All Claude sessions are done"
    static let batteryTitle = "Battery low, Vigil let go"

    /// "Done in vigil, 14 min, 38 commands."
    static func finished(project: String?, duration: TimeInterval?, tools: Int?) -> String {
        var parts = [project.map { "Done in \($0)" } ?? "A session is done"]
        if let duration { parts.append(length(duration)) }
        if let tools { parts.append(tools == 1 ? "1 command" : "\(tools) commands") }
        return parts.joined(separator: ", ") + "."
    }

    static func waiting(project: String?) -> String {
        project.map { "Waiting for your answer in \($0)." } ?? "A session is waiting for your answer."
    }

    static func allDoneBody(manualHold: Bool) -> String {
        manualHold ? "Your manual hold still keeps the Mac awake." : "Vigil let go. Your Mac now sleeps on its normal settings."
    }

    static func battery(percent: Int) -> String {
        "At \(percent)% on battery the Mac sleeps normally again. Plug in to keep it awake."
    }

    /// "Today: 3 tasks, 45 min working, longest 20 min."
    static func today(tasks: Int, working: TimeInterval, longest: TimeInterval?) -> String {
        guard tasks > 0 else { return "Today: no finished tasks yet." }
        let longestText = longest.map { ", longest \(length($0))" } ?? ""
        return "Today: \(tasks) task\(tasks == 1 ? "" : "s"), \(length(working)) working\(longestText)."
    }

    /// "45 s", "14 min", "2 h 5 min".
    static func length(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
