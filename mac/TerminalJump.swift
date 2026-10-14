import AppKit
import Foundation

/// Brings the Terminal tab running a Claude session to the front.
enum TerminalJump {
    /// The terminal device of the process, like "/dev/ttys004", or nil.
    static func tty(of pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        // No controlling terminal reads as all bits set.
        guard info.e_tdev != UInt32.max, let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    /// True when Terminal found and selected the tab. The tty is a device path we built, so it
    /// is checked before it goes into the script.
    @discardableResult
    static func show(pid: pid_t) -> Bool {
        // A session in iTerm or an editor has a tty too; never launch Terminal to look for it.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty else {
            return false
        }
        guard let tty = tty(of: pid), tty.range(of: #"^/dev/ttys[0-9]+$"#, options: .regularExpression) != nil else {
            return false
        }
        let source = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil { NSLog("Vigil could not reach Terminal") }
        return result?.booleanValue == true
    }
}
