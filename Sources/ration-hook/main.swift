import RationCore
import Foundation

// Claude Code hook helper: `ration-hook <busy|waiting|permission|ended> <state-dir>`.
// Reads the hook's JSON input from stdin and records the session's state for
// Ration. It only reads `session_id` and `hook_event_name`, never prompt or
// tool content, and always exits 0 so it can never block or disturb Claude Code.

let args = CommandLine.arguments
guard args.count >= 3, let state = HookStateRecord.State(rawValue: args[1]) else { exit(0) }
let dir = URL(fileURLWithPath: args[2], isDirectory: true)

let input = FileHandle.standardInput.readData(ofLength: 4 << 20)
guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
      let sessionId = object["session_id"] as? String else { exit(0) }

try? HookStateStore.record(state, sessionId: sessionId, event: object["hook_event_name"] as? String, in: dir)
exit(0)
