import AppKit

/// Quits and reopens the app bundle (used after settings that are read at launch).
@MainActor
enum Relauncher {
    static func relaunch() {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else {
            // Running outside a bundle (e.g. `swift run`): just quit.
            NSApp.terminate(nil)
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this process to exit, then reopen the bundle. Path passed as $0, not interpolated.
        task.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                          path, String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try task.run()
        } catch {
            NSApp.terminate(nil)
            return
        }
        NSApp.terminate(nil)
    }
}
