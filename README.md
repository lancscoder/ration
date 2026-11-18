# ClaudeBar

A native macOS menu bar app that shows your Claude plan usage (5-hour and weekly limits) and your Claude Code token activity and sessions.

```
⚡ 29% · 1h12m ●
```

- **Menu bar label:** choose the 5-hour limit, the weekly limit or both, then switch each part on or off in Settings: percent used, time until reset, reset time (e.g. `19:10`) and the session status dot (green while a Claude Code session is working, blue when one has just finished and is waiting for you). With all three text parts off, only the icon shows. The label turns amber at 60% and red at 85% (both configurable).
- **Limits:** progress bars for the 5-hour session, the weekly limit and any model-specific weekly limits. Each shows a countdown and the wall-clock reset time. Extra-usage spend and limit, plus the weekly per-product breakdown, appear underneath.
- **Burn rate:** %/hour over the last hour of the current 5-hour window, a forecast ("limit in ~2h10m" or "won't hit limit before reset"), and a sparkline of the window.
- **Tokens:** Today (hourly) / 7 days / 14 days / All, as stacked columns or a day list (one row per day, newest first, as in rodrigondec's plugin), with a per-model totals table (input, output, cache write, cache read). Cache reads are hidden by default; press `c` to toggle them.
- **Sessions:** running and recent sessions with project, model, state, last activity and tokens. **Resume** opens your terminal running `claude --resume <id>`. **Stop** sends SIGTERM after you confirm.
- **Notifications:** sent when usage crosses 75% or 90% (configurable), once per window. Optionally also when a session goes from working to waiting.
- **Panel:** **Open Claude** launches the Claude desktop app, or claude.ai if it isn't installed. Click a section title to collapse or expand it; ClaudeBar remembers your choice. Settings → Panel sections shows or hides each section. Hovering a footer button shows its name.
- **Keyboard (panel open):** `r` refreshes, `c` toggles cache reads, `Esc` closes.

Inspired by [rodrigondec/omarchy-claude-tokens](https://github.com/rodrigondec/omarchy-claude-tokens), [oguzkarcan/claude-usage](https://github.com/oguzkarcan/claude-usage), [mryll/claudebar](https://github.com/mryll/claudebar) and [ai-usagebar](https://github.com/akitaonrails/ai-usagebar).

## Requirements

- macOS 14 or later (built and tested on Apple Silicon)
- Swift 5.10+ toolchain (Xcode or the Command Line Tools)
- Claude Code, logged in with a Pro or Max subscription

## Build, run, install

Everything builds from the terminal with SwiftPM. No Xcode project is needed.

```sh
make test      # unit tests (swift test)
make run       # release build → build/ClaudeBar.app (ad-hoc signed) → launch
make install   # copy to ~/Applications/ClaudeBar.app and launch
make uninstall
make icon      # regenerate Resources/AppIcon.icns from scripts/make-icon.swift
```

`make app` runs `swift build -c release`, assembles `ClaudeBar.app` (Info.plist with `LSUIElement`, icon, PkgInfo) and signs it with `codesign -s -`. The app is **not sandboxed**, because it has to read `~/.claude` and run `/usr/bin/security`.

Turn on **Launch at login** in Settings. It uses `SMAppService.mainApp`, so run `make install` first, so that the login item points at `~/Applications`.

### First launch: Keychain prompt

Claude Code keeps its OAuth login in your login Keychain under the service `Claude Code-credentials`. ClaudeBar reads it with `security find-generic-password -s "Claude Code-credentials" -w`, so on the first read macOS asks whether `security` may access that item. Choose **Always Allow**. You may see the prompt again after Claude Code rewrites the item. macOS will also ask once for permission to show notifications.

## Data sources

### 1. Plan limits: `GET https://api.anthropic.com/api/oauth/usage`

> ⚠️ **This endpoint is undocumented** and may change or disappear without notice. ClaudeBar decodes it tolerantly: unknown keys are ignored, and a malformed block is dropped rather than failing the whole response. Missing model limits are simply hidden.

- **Headers:** `Authorization: Bearer <accessToken>` and `anthropic-beta: oauth-2025-04-20`.
- **Fields used:** `five_hour`, `seven_day` (`utilization`, `resets_at`), model-specific limits from `limits[]` entries with `kind: "weekly_scoped"` and `scope.model.display_name` (and the legacy `seven_day_opus`/`seven_day_sonnet` blocks if present), `extra_usage` (amounts in minor units) and `seven_day_breakdown`.
- **Credentials:** read-only. ClaudeBar tries the Keychain service `Claude Code-credentials-<first 8 hex of sha256(CLAUDE_CONFIG_DIR)>` when `CLAUDE_CONFIG_DIR` is set, then `Claude Code-credentials`, then `~/.claude/.credentials.json`. On current macOS builds that file is often a stale stub. **The token is never refreshed and the Keychain is never written**, so ClaudeBar can't race Claude Code's own refresh. If the token has expired, the panel says "Login stale. Run `claude` to refresh it". The token is never logged.
- **Rate limits:** polls every 5 minutes by default and never more often than that (configurable up to an hour). On HTTP 429 it backs off exponentially (honouring `Retry-After`) and keeps showing the last good data, marked stale. Manual refresh also respects the backoff and a 60 s minimum gap.
- **Cache:** the last good response goes to `~/Library/Caches/local.claudebar.ClaudeBar/usage.json`, so data shows immediately at launch. A launch within the poll interval doesn't call the endpoint again. Quota samples for the burn rate are kept for 48 h in `quota-samples.json`. You can move the cache folder in **Settings → Folders**; ClaudeBar moves its files and relaunches. The Claude Code folder (normally `~/.claude`, or `CLAUDE_CONFIG_DIR`) can be set there too, and replaces auto-detection for logs, sessions and the credentials lookup.

### 2. Token history: Claude Code session logs

- **Files read:** `~/.claude/projects/**/*.jsonl` (plus `~/.config/claude/projects` and `$CLAUDE_CONFIG_DIR/projects` if present), including subagent logs in `<session>/subagents/`.
- **What's counted:** only assistant entries carrying `message.usage`. Streamed responses write one line per content block with identical usage, so entries are deduplicated on `message.id|requestId`, keeping the largest `output_tokens`, across all files. `<synthetic>` messages and malformed lines are skipped.
- **Incremental parsing:** each file's byte offset, size, mtime, inode and parsed records are cached in `tokens.json`, so a refresh only reads new complete lines. A cold scan of about 700 MB of logs takes around 2–3 s. FSEvents triggers refreshes, with a 30 s timer as backup. No network is involved.
- **Aggregation:** by local-time day (hour for Today), by model and by session.

### 3. Session status

- **Main source:** Claude Code writes `~/.claude/sessions/<pid>.json` for every running process, with `sessionId`, `cwd`, `status` (`busy`/`idle`) and `procStart`. ClaudeBar checks that each PID is alive and that its start time matches `procStart`, so a recycled PID is never shown or killed.
- **Fallback:** if no status is reported, a transcript heuristic decides. A write in the last ~10 s, a pending `tool_use` or an unfinished turn means busy; a finished assistant turn means waiting. The logic lives in `SessionStateHeuristic` and is unit tested. A future hooks mode (`UserPromptSubmit`/`Stop`/`Notification` writing a state file) can feed the same `reportedStatus` input.
- **Resume:** writes a small `.command` script that `cd`s into the project and runs `claude --resume <id>` in an interactive login shell. Terminal.app and iTerm2 open it directly, so no AppleScript or Automation permission is needed. Ghostty runs it with `-e`. A custom command template can use `{script}`, `{cwd}`, `{sessionId}` and `{command}`.

## Architecture

```
Sources/ClaudeBarCore   data layer, no UI (reusable for a CLI/widget)
  CredentialStore       Keychain/file lookup (read-only)
  UsageAPIClient        endpoint client, Retry-After parsing
  UsageService (actor)  polling, backoff, cache, quota samples
  UsageCache (actor)    usage.json + quota-samples.json
  BurnRate              least-squares %/h + forecast
  LogParser             JSONL line parsing + dedup
  LogStore (actor)      incremental scanning + tokens.json
  TokenAggregator       day/hour × model, totals, per-session
  SessionMonitor        live sessions + state heuristic, ProcessControl
  ThresholdTracker      once-per-window notification logic
Sources/ClaudeBar       SwiftUI app: MenuBarExtra(.window), AppState (@Observable), views, settings
Tests/ClaudeBarCoreTests  Swift Testing; fixtures include a captured usage response (no token)
```

Logging goes through `os.Logger` with subsystem `local.claudebar.ClaudeBar`:

```sh
log stream --predicate 'subsystem == "local.claudebar.ClaudeBar"' --info
```

Debug flags (for checks without screen recording):

- `ClaudeBar.app/Contents/MacOS/ClaudeBar --snapshot <dir>` renders the label and panel from cached data to PNGs, then exits.
- `--stress <seconds>` floods the panel with synthetic mouse events while the app runs normally. Use `STRESS_MODE=idle` for no events.
- `STRESS_MODE=resize … --stress 30` collapses every section and prints the panel's window height before and after.

## Caveats

- The usage endpoint is undocumented and rate-limited. If Anthropic changes it, the limits section degrades to "no data", while local token stats keep working.
- Token counts come from local logs. They show what this machine's Claude Code sent, not your account-wide usage (chats, other devices).
- The app is ad-hoc signed for personal use. It isn't notarised, so if you copy it to another Mac you'll need to clear its quarantine attribute there.
