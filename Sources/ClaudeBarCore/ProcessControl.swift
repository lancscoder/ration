import Darwin
import Foundation

/// Liveness and start-time checks via `kill(0)` and `sysctl(KERN_PROC_PID)`,
/// so a recycled PID is never mistaken for (or killed as) a Claude session.
public enum ProcessControl {
    /// True if the process exists and belongs to this user.
    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    public static func startTime(_ pid: Int32) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    /// Parses Claude Code's `procStart` (`ps -o lstart` style, e.g. "Fri Nov 13 12:51:28 2026").
    public static func parseProcStart(_ s: String, timeZone: TimeZone = .current) -> Date? {
        let collapsed = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        for format in ["EEE MMM d HH:mm:ss yyyy", "EEE d MMM HH:mm:ss yyyy"] {
            f.dateFormat = format
            if let d = f.date(from: collapsed) { return d }
        }
        return nil
    }

    /// Alive, and (when known) started when the status file says it did.
    public static func matches(pid: Int32, procStart: String?) -> Bool {
        guard isAlive(pid) else { return false }
        guard let procStart, let expected = parseProcStart(procStart), let actual = startTime(pid) else { return true }
        return abs(actual.timeIntervalSince(expected)) <= 2
    }

    public enum TerminateError: Error, Equatable {
        case notRunning
        case pidReused
        case failed(Int32)
    }

    /// SIGTERM, after re-checking that the PID is still the same process.
    public static func terminate(pid: Int32, procStart: String?) throws {
        guard isAlive(pid) else { throw TerminateError.notRunning }
        guard matches(pid: pid, procStart: procStart) else { throw TerminateError.pidReused }
        guard pid != getpid() else { throw TerminateError.failed(EPERM) }
        if kill(pid, SIGTERM) != 0 { throw TerminateError.failed(errno) }
    }
}

/// Builds the shell snippet that resumes a session.
public enum ResumeCommand {
    /// Session ids are UUIDs; refuse anything that could smuggle shell syntax.
    public static func isSafeSessionId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 100 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `claude --resume <id>`
    public static func claudeCommand(sessionId: String) -> String {
        "claude --resume \(sessionId)"
    }

    /// Contents of a `.command` script: cd into the project and run claude in an
    /// interactive login shell (so PATH from .zshrc/.zprofile applies), then
    /// leave a shell open when claude exits.
    public static func script(cwd: String, sessionId: String) -> String? {
        guard isSafeSessionId(sessionId) else { return nil }
        let inner = "\(claudeCommand(sessionId: sessionId)); exec \"${SHELL:-/bin/zsh}\" -l"
        return """
        #!/bin/zsh
        cd -- \(shellQuote(cwd)) || exit 1
        exec "${SHELL:-/bin/zsh}" -lic \(shellQuote(inner))

        """
    }

    /// Expands a user template. Placeholders: `{cwd}`, `{sessionId}`, `{command}`, `{script}` (all shell-quoted).
    public static func expand(template: String, cwd: String, sessionId: String, scriptPath: String) -> String {
        template
            .replacingOccurrences(of: "{cwd}", with: shellQuote(cwd))
            .replacingOccurrences(of: "{sessionId}", with: shellQuote(sessionId))
            .replacingOccurrences(of: "{command}", with: shellQuote(claudeCommand(sessionId: sessionId)))
            .replacingOccurrences(of: "{script}", with: shellQuote(scriptPath))
    }
}
