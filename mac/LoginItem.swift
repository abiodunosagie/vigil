import Foundation

/// Starts Vigil at login through a user LaunchAgent.
enum LoginItem {
    static let label = "com.abiodun.vigil"

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
