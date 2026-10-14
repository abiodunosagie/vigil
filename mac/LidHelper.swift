import Foundation

/// The optional root helper that keeps the Mac awake with the lid closed (lid/vigil-lid.sh).
///
/// Installing needs the user's admin password once. After that Vigil only touches a heartbeat
/// file in its own folder; the helper, run by launchd every 15 seconds, holds lid sleep off while
/// the heartbeat is fresh and puts it back within about 45 seconds of the heartbeat stopping.
enum LidHelper {
    static let label = "com.abiodun.vigil.lid"
    static let script = "/Library/PrivilegedHelperTools/\(label)"
    static let plist = "/Library/LaunchDaemons/\(label).plist"
    static let heartbeat = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Vigil/lid-heartbeat")

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: script) && FileManager.default.fileExists(atPath: plist)
    }

    /// Keeps the heartbeat fresh while `on`; removes it otherwise so the helper lets go.
    static func beat(_ on: Bool) {
        if on {
            let path = heartbeat.path
            if !FileManager.default.createFile(atPath: path, contents: nil) {
                NSLog("Vigil lid heartbeat not written")
            }
        } else if FileManager.default.fileExists(atPath: heartbeat.path) {
            try? FileManager.default.removeItem(at: heartbeat)
        }
    }

    enum Failure: Error { case missingScript, cancelled, failed }

    /// Installs the helper, asking for the admin password.
    static func install() throws {
        guard let source = Bundle.main.path(forResource: "vigil-lid", ofType: "sh") else { throw Failure.missingScript }
        let daemon: [String: Any] = [
            "Label": label,
            "ProgramArguments": [script, heartbeat.path],
            "StartInterval": 15,
            "RunAtLoad": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: daemon, format: .xml, options: 0)
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("\(label).plist")
        try data.write(to: staged, options: .atomic)
        let commands = [
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/usr/bin/install -o root -g wheel -m 755 \(quote(source)) \(quote(script))",
            "/usr/bin/install -o root -g wheel -m 644 \(quote(staged.path)) \(quote(plist))",
            "/bin/launchctl bootout system/\(label) 2>/dev/null; /bin/launchctl bootstrap system \(quote(plist))",
        ]
        try runAsAdmin(commands.joined(separator: " && "))
        try? FileManager.default.removeItem(at: staged)
    }

    /// Removes the helper and puts lid sleep back, asking for the admin password.
    static func uninstall() throws {
        let commands = [
            "/bin/launchctl bootout system/\(label) 2>/dev/null",
            "\(quote(script)) --restore",
            "/bin/rm -f \(quote(script)) \(quote(plist))",
            "/bin/rm -rf '/Library/Application Support/VigilLid'",
        ]
        try runAsAdmin(commands.joined(separator: "; "))
        beat(false)
    }

    /// Single quotes for the shell, so a path with spaces or quotes stays one argument.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runAsAdmin(_ command: String) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        _ = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        if let error {
            // -128 is the user pressing Cancel on the password prompt.
            throw (error[NSAppleScript.errorNumber] as? Int) == -128 ? Failure.cancelled : Failure.failed
        }
    }
}
