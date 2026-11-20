# Ration

Make your Claude limits last. Ration is a native macOS menu bar app for Claude Code users: it shows your plan usage (5-hour and weekly limits), how fast you're burning through them, your token activity and your running sessions.

> Ration is an independent open-source project. It is not affiliated with or endorsed by Anthropic.

```
⚡ 29% · 1h12m ●
```

- **Menu bar label:** choose the 5-hour limit, the weekly limit or both, then switch each part on or off in Settings: percent used, time until reset, reset time (e.g. `19:10`) and the session status dot (green while a Claude Code session is working, blue when one has just finished and is waiting for you). With all three text parts off, only the icon shows. The label turns amber at 60% and red at 85% (both configurable).
- **Limits:** progress bars for the 5-hour session, the weekly limit and any model-specific weekly limits. Each shows a countdown and the wall-clock reset time. Extra-usage spend and limit, plus the weekly per-product breakdown, appear underneath.
- **Burn rate:** %/hour over the last hour of the current 5-hour window, a forecast ("limit in ~2h10m" or "won't hit limit before reset"), and a sparkline of the window. Below it, the weekly pace over the last day ("on pace for ~66% by Thu 17:00", or when you'd hit the weekly limit).
- **Tokens:** Today (hourly) / 7 days / 14 days / All, as stacked columns or a day list (one row per day, newest first, as in rodrigondec's plugin), with a totals table (input, output, cache write, cache read) by model or by project folder. Cache reads are hidden by default; press `c` to toggle them.
- **Sessions:** running sessions (with **Stop**, which sends SIGTERM after you confirm) and sessions that ended recently (last 7 days by default, configurable; with **Resume**, which opens your terminal running `claude --resume <id>`), showing project, model, state, last activity and tokens. Each row's **…** menu (or right-click) can show the folder in Finder or copy its path, the resume command or the session ID.
- **Notifications:** sent when usage crosses 75% or 90% (configurable), once per window, and at the moment a limit resets if you'd used 90% or more of it. Optionally also when a session goes from working to waiting (or needs permission, with hooks).
- **Panel:** **Open Claude** launches the Claude desktop app, or claude.ai if it isn't installed. Click a section title to collapse or expand it; Ration remembers your choice. Settings → Panel sections shows or hides each section. Hovering a footer button shows its name.
- **Keyboard:** set a global shortcut in Settings → Menu bar to open the panel from anywhere. With the panel open, `r` refreshes, `c` toggles cache reads, `Esc` closes.
- **Sleep:** after the Mac wakes, local data refreshes immediately and usage within a few seconds (still never more often than every 5 minutes).
- **VoiceOver:** the menu bar item, limits, charts, token rows and sessions all have spoken labels.

Inspired by [rodrigondec/omarchy-claude-tokens](https://github.com/rodrigondec/omarchy-claude-tokens), [oguzkarcan/claude-usage](https://github.com/oguzkarcan/claude-usage), [mryll/claudebar](https://github.com/mryll/claudebar) and [ai-usagebar](https://github.com/akitaonrails/ai-usagebar).

## Install

Requires macOS 14 or later and Claude Code logged in with a Pro or Max subscription.

### Homebrew

```sh
brew tap lancscoder/tap
brew trust lancscoder/tap     # Homebrew asks you to trust third-party taps once
brew install --cask ration
```

### Download

Grab `Ration-<version>.zip` from the [latest release](https://github.com/lancscoder/ration/releases/latest), unzip it and move `Ration.app` to Applications.

### First launch: "Open Anyway"

Ration isn't signed with an Apple Developer ID yet, so macOS blocks it the first time. Open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Or clear the quarantine flag yourself:

```sh
xattr -dr com.apple.quarantine /Applications/Ration.app
```

You only need to do this once: updates installed by Ration itself aren't quarantined.

### Updates

Ration checks GitHub Releases once a day (Settings → Updates, where you can turn it off or check now). When there's a new version, the panel shows **Install**: Ration downloads it, checks its signature, swaps itself in place and relaunches.

Every release zip is signed with an Ed25519 key held by the maintainer, and Ration refuses anything whose signature doesn't match the public key built into the app, isn't a newer version, or isn't Ration. Builds you make yourself with `make app` don't replace themselves; they link to the release page instead.

### Build from source

Everything builds from the terminal with SwiftPM (Swift 5.10+, from Xcode or the Command Line Tools). No Xcode project is needed.

```sh
git clone https://github.com/lancscoder/ration.git && cd ration
make install   # build, copy to ~/Applications/Ration.app and launch
```

Other targets:

```sh
make test      # unit tests (swift test)
make run       # release build → build/Ration.app (ad-hoc signed) → launch
make uninstall
make icon      # regenerate Resources/AppIcon.icns from scripts/make-icon.swift
```

`make app` runs `swift build -c release`, assembles `Ration.app` (Info.plist with `LSUIElement`, icon, PkgInfo, the hook helper) and signs it ad hoc with `codesign -s -`. The app is **not sandboxed**, because it has to read `~/.claude` and run `/usr/bin/security`. That's also why it isn't on the Mac App Store.

Turn on **Launch at login** in Settings. It uses `SMAppService.mainApp`, so keep the app in Applications.

### First launch: Keychain prompt

Claude Code keeps its OAuth login in your login Keychain under the service `Claude Code-credentials`. Ration reads it with `security find-generic-password -s "Claude Code-credentials" -w`, so on the first read macOS asks whether `security` may access that item. Choose **Always Allow**. You may see the prompt again after Claude Code rewrites the item. macOS will also ask once for permission to show notifications.

## Data sources

### 1. Plan limits: `GET https://api.anthropic.com/api/oauth/usage`

> ⚠️ **This endpoint is undocumented** and may change or disappear without notice. Ration decodes it tolerantly: unknown keys are ignored, and a malformed block is dropped rather than failing the whole response. Missing model limits are simply hidden.

- **Headers:** `Authorization: Bearer <accessToken>` and `anthropic-beta: oauth-2025-04-20`.
- **Fields used:** `five_hour`, `seven_day` (`utilization`, `resets_at`), model-specific limits from `limits[]` entries with `kind: "weekly_scoped"` and `scope.model.display_name` (and the legacy `seven_day_opus`/`seven_day_sonnet` blocks if present), `extra_usage` (amounts in minor units) and `seven_day_breakdown`.
- **Credentials:** read-only. Ration tries the Keychain service `Claude Code-credentials-<first 8 hex of sha256(CLAUDE_CONFIG_DIR)>` when `CLAUDE_CONFIG_DIR` is set, then `Claude Code-credentials`, then `~/.claude/.credentials.json`. On current macOS builds that file is often a stale stub. **The token is never refreshed and the Keychain is never written**, so Ration can't race Claude Code's own refresh. If the token has expired, the panel says "Login stale. Run `claude` to refresh it". The token is never logged.
- **Rate limits:** polls every 5 minutes by default and never more often than that (configurable up to an hour). On HTTP 429 it backs off exponentially (honouring `Retry-After`) and keeps showing the last good data, marked stale. Manual refresh also respects the backoff and a 60 s minimum gap.
- **Cache:** the last good response goes to `~/Library/Caches/io.github.lancscoder.ration/usage.json`, so data shows immediately at launch. A launch within the poll interval doesn't call the endpoint again. Quota samples for the burn rate are kept for 48 h in `quota-samples.json`. You can move the cache folder in **Settings → Folders**; Ration moves its files and relaunches. The Claude Code folder (normally `~/.claude`, or `CLAUDE_CONFIG_DIR`) can be set there too, and replaces auto-detection for logs, sessions and the credentials lookup.

### 2. Token history: Claude Code session logs

- **Files read:** `~/.claude/projects/**/*.jsonl` (plus `~/.config/claude/projects` and `$CLAUDE_CONFIG_DIR/projects` if present), including subagent logs in `<session>/subagents/`.
- **What's counted:** only assistant entries carrying `message.usage`. Streamed responses write one line per content block with identical usage, so entries are deduplicated on `message.id|requestId`, keeping the largest `output_tokens`, across all files. `<synthetic>` messages and malformed lines are skipped.
- **Incremental parsing:** each file's byte offset, size, mtime, inode and parsed records are cached in `tokens.json`, so a refresh only reads new complete lines. A cold scan of about 700 MB of logs takes around 2–3 s. FSEvents triggers refreshes, with a 30 s timer as backup. No network is involved.
- **Aggregation:** by local-time day (hour for Today), by model and by session.

### 3. Session status

- **Main source:** Claude Code writes `~/.claude/sessions/<pid>.json` for every running process, with `sessionId`, `cwd`, `status` (`busy`/`idle`) and `procStart`. Ration checks that each PID is alive and that its start time matches `procStart`, so a recycled PID is never shown or killed.
- **Fallback:** if no status is reported, a transcript heuristic decides. A write in the last ~10 s, a pending `tool_use` or an unfinished turn means busy; a finished assistant turn means waiting. The logic lives in `SessionStateHeuristic` and is unit tested.
- **Hooks mode (optional):** Settings → Sessions → *Exact status via Claude Code hooks* adds entries to `~/.claude/settings.json` (backed up to `settings.json.ration-backup`; other hooks and settings are kept). `UserPromptSubmit` and `PostToolUse` report busy, `PermissionRequest` and `Notification` (`permission_prompt`) report *needs permission*, `Notification` (`idle_prompt`) and `Stop` report waiting, and `SessionEnd` clears the state. Each runs the bundled `Contents/Helpers/ration-hook`, which reads only `session_id` and `hook_event_name` from the hook input and writes `~/Library/Application Support/io.github.lancscoder.ration/hook-state/<session>.json`. It always exits 0, and the command is guarded so a moved or deleted app never breaks Claude Code. The newer of the hook state and Claude Code's own status wins; *needs permission* holds until Claude Code reports busy again. Remove them from the same place.
- **Resume:** terminals are detected automatically: a known list (Terminal, iTerm2, Ghostty, cmux, Warp, WezTerm, kitty, Alacritty, Orca, Hyper, Tabby) plus any other app that registers as a *Shell* for shell scripts. Ration writes a small `.command` script that `cd`s into the project and runs `claude --resume <id>` in an interactive login shell. Apps that run shell scripts open it directly (no AppleScript, no Automation permission). Ghostty, WezTerm, kitty and Alacritty get it through their command-line options. Apps that can't be told to run a command (Orca, Hyper, Tabby) are opened and the command is copied to the clipboard to paste. A custom command template can use `{script}`, `{cwd}`, `{sessionId}` and `{command}`.

## Architecture

```
Sources/RationCore     data layer, no UI (reusable for a CLI/widget)
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
  Hooks                 hooks-mode installer + state store
  Updates               release feed, version compare, update signatures
Sources/Ration         SwiftUI app: MenuBarExtra(.window), AppState (@Observable), views, settings
Sources/ration-hook    helper run by Claude Code hooks
Tests/RationCoreTests  Swift Testing; fixtures include a captured usage response (no token)
```

Logging goes through `os.Logger` with subsystem `io.github.lancscoder.ration`:

```sh
log stream --predicate 'subsystem == "io.github.lancscoder.ration"' --info
```

Debug flags (for checks without screen recording):

- `Ration.app/Contents/MacOS/Ration --snapshot <dir>` renders the label and panel from cached data to PNGs, then exits.
- `--stress <seconds>` floods the panel with synthetic mouse events while the app runs normally. Use `STRESS_MODE=idle` for no events.
- `STRESS_MODE=resize … --stress 30` collapses every section and prints the panel's window height before and after.
- `STRESS_MODE=quick QUICK_OUT=<png> … --stress 20` registers a test shortcut, opens the shortcut panel, prints where it landed, saves a picture and closes it.

## Caveats

- The usage endpoint is undocumented and rate-limited. If Anthropic changes it, the limits section degrades to "no data", while local token stats keep working.
- Token counts come from local logs. They show what this machine's Claude Code sent, not your account-wide usage (chats, other devices).
- Because the app is ad-hoc signed, its code signature changes with each version, so macOS may ask again for Keychain access after an update. Choose **Always Allow**.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for how releases are built and published.

## Licence

[MIT](LICENSE)
