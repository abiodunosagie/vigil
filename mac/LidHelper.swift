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

    /// Logged once per run, not on every 3 second tick.
    nonisolated(unsafe) private static var reportedBeatFailure = false

    /// Keeps the heartbeat fresh while `on`; removes it otherwise so the helper lets go.
    static func beat(_ on: Bool) {
        if on {
            if !FileManager.default.createFile(atPath: heartbeat.path, contents: nil), !reportedBeatFailure {
                reportedBeatFailure = true
                NSLog("Vigil lid heartbeat not written")
            }
        } else if FileManager.default.fileExists(atPath: heartbeat.path) {
            try? FileManager.default.removeItem(at: heartbeat)
        }
    }

    enum Failure: Error { case cancelled, failed }

    /// Seconds between helper runs; with the helper's 45 second heartbeat limit, lid sleep is
    /// back at most about a minute after Vigil stops.
    static let interval = 15

    /// The launchd job, as XML.
    static func daemonPlist() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "Label": label,
            "ProgramArguments": [script, heartbeat.path],
            "StartInterval": interval,
            "RunAtLoad": true,
        ] as [String: Any], format: .xml, options: 0)
    }

    /// The admin command that installs the helper. Root writes both files from text carried
    /// inside this command (base64, built into Vigil), never from a file a user process could
    /// swap while the password prompt is open.
    static func installCommand(script scriptText: Data, plist plistData: Data) -> String {
        let s = scriptText.base64EncodedString(), p = plistData.base64EncodedString()
        return [
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/bin/echo '\(s)' | /usr/bin/base64 -D > \(quote(script))",
            "/usr/sbin/chown root:wheel \(quote(script))",
            "/bin/chmod 755 \(quote(script))",
            "/bin/echo '\(p)' | /usr/bin/base64 -D > \(quote(plist))",
            "/usr/sbin/chown root:wheel \(quote(plist))",
            "/bin/chmod 644 \(quote(plist))",
            "/usr/bin/plutil -lint -s \(quote(plist))",
            // Replace a running copy: bootout returns before launchd lets go of the label.
            "{ /bin/launchctl bootout system/\(label) 2>/dev/null; /bin/sleep 1; /bin/launchctl bootstrap system \(quote(plist)); }",
        ].joined(separator: " && ")
    }

    /// Installs the helper, asking for the admin password.
    static func install() throws {
        guard let scriptText = Data(base64Encoded: LidScript.base64) else { throw Failure.failed }
        try runAsAdmin(installCommand(script: scriptText, plist: try daemonPlist()))
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
