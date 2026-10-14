import Darwin
import Foundation

/// Finds commands Claude Code's Bash tool is still running for a session.
///
/// Every Bash tool command runs as a direct child of the `claude` process:
/// `/bin/zsh -c source ~/.claude/shell-snapshots/snapshot-... && ... <command>`.
/// After Claude's turn ends, such a child that is still alive is a command it left running
/// in the background. Claude Code's other children (MCP servers, `caffeinate`, language
/// servers) never carry that marker.
enum ProcessTree {
    static let bashToolMarker = "/.claude/shell-snapshots/"

    /// How many Bash tool commands `pid` is running right now.
    static func runningCommands(of pid: pid_t) -> Int {
        children(of: pid).filter { arguments(of: $0)?.contains(bashToolMarker) == true }.count
    }

    static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let bytes = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        // Returns the number of pids (checked on macOS 27: 10 children came back as 10).
        // Capped at the buffer; a Claude session has a dozen children, not 256.
        let count = min(Int(bytes), buffer.count)
        return buffer.prefix(count).filter { $0 > 0 }
    }

    /// The process's command line, joined with spaces, or nil when it cannot be read.
    static func arguments(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &data, &size, nil, 0) == 0 else { return nil }
        // Layout: argc (Int32), the executable path, NUL padding, then argc NUL-terminated args.
        let argc = data.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, data[index] != 0 { index += 1 }
        while index < size, data[index] == 0 { index += 1 }
        var args: [String] = []
        while index < size, args.count < Int(argc) {
            let start = index
            while index < size, data[index] != 0 { index += 1 }
            args.append(String(decoding: data[start..<index], as: UTF8.self))
            index += 1
        }
        return args.isEmpty ? nil : args.joined(separator: " ")
    }
}
