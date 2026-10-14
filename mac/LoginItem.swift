import Combine
import Foundation

/// Starts Vigil at login through a user LaunchAgent, the same way the owner's other menu bar
/// apps do. Unlike SMAppService, it needs no approval in System Settings for an ad hoc
/// signed app built on this Mac.
enum LoginItem {
    static let label = AppInfo.bundleID

    enum Failure: Error { case noExecutable }

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func set(enabled: Bool) throws {
        if !enabled {
            if isEnabled { try FileManager.default.removeItem(at: plistURL) }
            return
        }
        guard let executable = Bundle.main.executablePath else { throw Failure.noExecutable }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
    }
}

/// The panel's Launch at login switch. Re-read each time the panel opens, so a change made
/// elsewhere shows, and a failed change reports instead of silently flipping back.
@MainActor
final class LoginSwitch: ObservableObject {
    @Published private(set) var isOn = LoginItem.isEnabled
    @Published private(set) var error: String?

    func reload() {
        isOn = LoginItem.isEnabled
        error = nil
    }

    func set(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled: enabled)
            error = nil
        } catch {
            self.error = "Could not change the login setting."
        }
        isOn = LoginItem.isEnabled
    }
}
