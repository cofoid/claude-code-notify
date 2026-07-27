# claude-code-notify

Rich macOS notifications for [Claude Code](https://claude.com/claude-code). Tells you *which* session wants you, *what* it wants, and takes you straight there when you click.

Out of the box Claude Code makes no sound and posts nothing when a turn finishes or a permission prompt appears. If you run several sessions across terminal tabs, you either sit and watch or you come back late.

<!-- Replace with a real screenshot before publishing. -->

```
🩵 🔐 consulting-os
   Claude Audible Alerts · Permission needed
   Claude needs your permission to use Write
```

- **Colour square** — the session's `/color`, so parallel sessions are distinguishable at a glance
- **Icon** — 🔐 permission, ⏳ waiting, 💬 input, ✅ complete
- **Title** — the project directory
- **Subtitle** — the session's `/rename` name, plus what kind of attention it wants
- **Body** — the actual permission text, or a summary of what just finished
- **Click** — focuses the exact terminal tab that session is running in

## Requirements

- macOS (uses Notification Center)
- `jq` — payload parsing. Preinstalled on recent macOS; otherwise `brew install jq`
- `python3` — detaches the click listener. Ships with Xcode Command Line Tools
- [`alerter`](https://github.com/vjeantet/alerter) — installed for you, see below
- Click-to-tab needs [Ghostty](https://ghostty.org). Other terminals get app-level activation

## Install

```sh
git clone https://github.com/YOUR_USERNAME/claude-code-notify.git
cd claude-code-notify
./install.sh
```

Then paste the printed snippet into `~/.claude/settings.json` and restart Claude Code.

The installer verifies `alerter`'s notarized signature with `spctl` before installing it, and refuses if verification fails. It won't edit `settings.json` for you — that file usually holds hand-tuned permissions, and an automated merge is a bad trade against printing six lines.

### First-run permissions

macOS will prompt twice. Approve both:

1. **alerter wants to send notifications** — on the first alert
2. **osascript wants to control Ghostty** — on the first click

Then make banners stick around: **System Settings → Notifications → alerter → Alert style → Alerts**. Otherwise they auto-hide in a few seconds, which defeats the point if you stepped away.

## Configuration

Sounds are the hook argument — any basename from `/System/Library/Sounds` or `~/Library/Sounds`:

```json
"command": "$HOME/.claude/hooks/notify.sh Hero"
```

Everything else is environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_NOTIFY_TERM_APP` | `Ghostty` | Terminal to focus on click |
| `CLAUDE_NOTIFY_TIMEOUT` | `45` | Seconds to listen for a click |
| `CLAUDE_NOTIFY_ALERTER` | `~/.local/bin/alerter` | Path to the alerter binary |

## How it works

Claude Code pipes a JSON payload to hooks on stdin. The useful fields differ per event:

| Field | `Stop` | `Notification` |
|---|---|---|
| `message` | always `null` | generic string, never names the tool |
| `notification_type` | — | `permission_prompt`, etc. — the real classifier |
| `last_assistant_message` | tail of Claude's reply | `null` |
| `cwd`, `session_id`, `transcript_path` | ✅ | ✅ |

Two things you'd expect in the payload aren't there:

- **Session name** (`/rename`) lives in `~/.claude/sessions/<pid>.json` as `.name`, keyed by `sessionId`. Files are per-pid, so match on `sessionId` rather than guessing a filename.
- **Session colour** (`/color`) lives in the transcript as `{"type":"agent-color","agentColor":"..."}` entries, re-emitted each turn — the last wins. Read a bounded tail; transcripts reach tens of MB.

Click-to-tab uses Ghostty's AppleScript dictionary (`focus <terminal>`), matching the surface whose title contains the session name — Claude Code writes it into the terminal title. Falls back to working directory, but only on a unique match, since several tabs commonly share a repo.

## Known limitations

**Input alerts lag 1.5–6 seconds.** `Stop` is instant. `Notification` is late and variable, and it's the harness, not this script — proven by firing a local terminal bell and a Notification Center banner from the same hook and watching both arrive late together. Two delivery paths sharing no downstream machinery means the delay is upstream. Nothing here can fix it.

**No banner colour.** macOS exposes no banner-tint API. The colour square is the closest proxy.

**Clicking activates the app, then the tab.** No terminal offers direct per-tab activation; the AppleScript hop is what gets you the rest of the way, and only Ghostty ships a dictionary that allows it.

**Truncation is character-safe but not grapheme-safe.** A 140-character clip can split an emoji ZWJ sequence. Cosmetic, rare.

## Dead ends (already tested — don't repeat these)

**`terminal-notifier` does not work on current macOS.** The Homebrew formula is 2.0.0 from 2017, built on `NSUserNotification` — deprecated in 10.14, no longer delivered. It exits 0, never registers with Notification Center, delivers nothing, and never appears in System Settings. No configuration fixes it; the API is gone. `alerter` is the maintained replacement on `UNUserNotificationCenter`.

**`afplay` in a hook is the wrong tool.** It blocks on audio-device open plus the full sound duration (~2.4s for a 2.16s file), delaying anything sequenced after it. Backgrounding it is worse — Claude Code reaps the hook's process group and the sound is cut off entirely, so you hear nothing. Let the notification system play the sound: one process, ~0.07s.

**Hooks have no controlling terminal.** `> /dev/tty` fails with "device not configured", and the usual `|| printf '\a'` fallback writes to stdout, which Claude Code captures and swallows. To reach the terminal you must resolve the pty explicitly via `ps -o tty= -p $PPID`.

**Backgrounding the click listener isn't enough.** Claude Code reaps the hook's process group. The listener needs `fork()` + `setsid()` to survive in its own session.

**Never pass `--sender` to alerter.** Impersonating your terminal's bundle id makes it hang.

## Uninstall

```sh
./install.sh --uninstall
```

Then remove the `Stop` and `Notification` entries from `~/.claude/settings.json`.

## Licence

MIT — see [LICENSE](LICENSE).
