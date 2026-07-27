# Dead ends and other learnings

Everything here was tested on macOS 26.5 against Claude Code 2.1.220. It's written for anyone extending this project or building their own Claude Code notification hook — most of these approaches look correct, and several fail *silently*, exiting 0 while delivering nothing.

## Notification delivery

### `terminal-notifier` no longer works — this is not fixable by configuration

The Homebrew formula is 2.0.0, built November 2017 on `NSUserNotification`, an API Apple deprecated in 10.14 and current macOS no longer delivers. It exits 0, never registers with Notification Center, posts nothing, and never appears in System Settings → Notifications.

The absence from System Settings is the tell, and it's easy to misread as "it needs to be enabled first" — it isn't. An app appears there only after it successfully registers. No amount of permission-granting or flag-tweaking will help.

`NSUserNotification` also can't be used from a plain Foundation tool, which is why terminal-notifier ships as an app bundle in the first place. That constraint is inherited by anything built on it.

**Use instead:** [`alerter`](https://github.com/vjeantet/alerter), a Swift rewrite on `UNUserNotificationCenter`. Not in Homebrew, and the `vjeantet/alerter` tap referenced in some write-ups doesn't exist — install from the GitHub release, which is Developer ID signed and notarized.

### `osascript` works, but the click always opens Script Editor

`osascript -e 'display notification ...'` delivers reliably and is a fine fallback. But notifications post under the identity of the app that sent them, and for `osascript` that's Script Editor (`com.apple.ScriptEditor2`). Clicking one opens Script Editor.

This isn't overridable — the posting app owns the click target. It also means the alert-style setting you need to change is Script Editor's, not your terminal's, which is confusing enough to waste real time.

### Never pass `--sender` to alerter

`--sender <bundle-id>` looks like the way to make notifications appear to come from your terminal. Passing your terminal's bundle id makes alerter **hang**. macOS validates `--sender` against the process's actual bundle identity and silently drops the mismatch. Let it default.

## Audio

### Don't use `afplay` in a hook

`afplay` blocks on audio-device open *and* for the full duration of the sound — measured at 2.4–2.9s wall clock for a 2.16s file at ~1% CPU. Anything sequenced after it is delayed by that much, so a banner posted after the sound arrives seconds late.

Backgrounding it (`afplay ... &`) is worse: Claude Code reaps the hook's process group when the hook returns, cutting the sound off before it plays. You hear nothing at all, which reads as "the hook didn't fire" and sends you debugging the wrong thing.

**Use instead:** let the notification system play the sound. `osascript ... sound name "Hero"` or `alerter --sound Hero` is one process, ~0.07s, with the audio and banner together. Sound names are basenames from `/System/Library/Sounds` or `~/Library/Sounds`.

### An external audio interface adds seconds of wake latency

If the default output is a USB or Thunderbolt audio interface, it powers down when idle and takes seconds to wake. This compounds any `afplay` delay and is easy to blame on the hook. Switch the default output to internal speakers to isolate it — or set System Settings → Sound → **Alert sound output device** to something always-awake.

## The hook execution environment

### Hooks have no controlling terminal

`printf '\a' > /dev/tty` fails with `device not configured`. The idiomatic fallback, `printf '\a' > /dev/tty 2>/dev/null || printf '\a'`, then writes the bell to stdout — which Claude Code captures and swallows. Net result: no bell, no error, nothing to debug.

To reach the terminal, resolve the pty explicitly. `$PPID` is the `claude` process, which does own one:

```sh
t=$(ps -o tty= -p "$PPID" | tr -d ' ')
[ -n "$t" ] && [ "$t" != "??" ] && printf '\a' > "/dev/$t"
```

Worth knowing: `ps` may be blocked by Claude Code's Bash sandbox while working *interactively*, but runs fine inside a hook.

### Backgrounding isn't enough to outlive the hook — you need a new session

Claude Code reaps the hook's process group on return. A plain `cmd &` subshell is killed with it. This matters for `alerter`, which blocks while waiting for a click (that's how it reports `@CONTENTCLICKED`) — background it naively and the banner appears but clicks do nothing.

`fork()` + `setsid()` puts the listener in its own session, where it survives:

```python
if os.fork() > 0:
    sys.exit(0)   # hook returns immediately
os.setsid()       # escape the reaped process group
```

Note `nohup` alone is insufficient: it only ignores SIGHUP, and this is a process-group termination.

### Hooks are read fresh on every invocation

Only `settings.json` needs a Claude Code restart. If it points at a script, edits to that script take effect immediately — so develop against the script, not inline commands.

## Payload fields

Claude Code pipes JSON to hooks on stdin. Observed keys: `hook_event_name`, `session_id`, `transcript_path`, `cwd`, `message`, `notification_type`, `last_assistant_message`, `permission_mode`, `effort`, `prompt_id`, `background_tasks`, `session_crons`, `stop_hook_active`.

Which are *populated* differs by event, and the obvious field is often the wrong one:

- **`Notification`** — `message` is generic ("Claude needs your permission") and never names the tool. `notification_type` is the real classifier (`permission_prompt`). `last_assistant_message` is null.
- **`Stop`** — `message` is **always null**. Build a banner from it and every completion shows your fallback text. The useful content is `last_assistant_message`, the tail of Claude's final text block.

Log the raw payload to a file for a few real invocations before assuming any of this. It's undocumented and cheaper to observe than to guess.

## Session identity

Two things you'd reasonably expect in the payload aren't there.

**Session name** (`/rename`) is in `~/.claude/sessions/<pid>.json` as `.name`. Files are keyed by pid, not session, so scan them and match `.sessionId` against the payload's `session_id` rather than guessing a filename.

**Session colour** (`/color`) isn't in any config file — not `~/.claude.json`, not the session file. It's written into the session transcript as `{"type":"agent-color","agentColor":"..."}` entries, re-emitted every turn, so the last one wins. Read a bounded tail (`tail -c 200000`); transcripts reach tens of MB and this runs on every turn.

There are exactly **8 colours**: red, blue, green, yellow, purple, orange, pink, cyan. `gray`, `grey`, `default`, `none`, and `reset` are *reset aliases*, not colours. Six have an exact Unicode square (🟥🟦🟩🟨🟪🟧); pink and cyan don't, and 🩷/🩵 are the closest single glyphs. Teal, magenta, brown, white, and black don't exist — don't build mappings for them.

## Click-through to a specific terminal tab

Focusing the terminal *app* is easy. Focusing the right *tab* seems impossible and isn't, at least for Ghostty.

Ghostty ships an AppleScript dictionary (`NSAppleScriptEnabled = 1`, `/Applications/Ghostty.app/Contents/Resources/Ghostty.sdef`) exposing `window`/`tab`/`terminal` classes and `focus`, `select tab`, `activate window`. `focus <terminal>` fronts the window and focuses the surface in one call. **Check for an `.sdef` before reaching for accessibility/System Events UI scripting** — the latter needs assistive access and is far more fragile.

The match key is the terminal title: Claude Code writes the session name into it, rendered like `⠂ My Session Name`. The leading glyph is a live status spinner, so match by *containment*, never equality.

Two guards worth copying:

- Skip title matching when the session name is empty — `contains ""` is true for every surface and will focus an arbitrary tab.
- Accept a working-directory fallback only on a **unique** match. Several tabs routinely sit in the same repo, and a non-unique match is a coin flip.

## Timing

`Stop` fires essentially instantly. `Notification` lags **1.5–6 seconds**, and the lag is variable rather than a fixed cost.

That delay is in Claude Code's hook dispatch, not in delivery. The proof: fire a local terminal bell and a Notification Center banner from the same hook. They share no downstream machinery, and both arrive late together — so the delay is upstream of both. No change to the notification tooling will fix it. Don't spend time on it.

## Environment gotchas

**Guard for macOS.** A `settings.json` at `~/.claude/` is read by Linux devcontainers too. An unguarded `osascript` call errors on every single turn in a container. `[ "$(uname)" = "Darwin" ] || exit 0`.

**Check your interpreters exist before branching on them.** If a delivery path needs `python3` and it's missing, a branch that takes the path and then `exit 0`s skips the fallback and delivers nothing, silently. On a Mac without Command Line Tools, `/usr/bin/python3` is a stub that *hangs* prompting to install them — inside a hook, that's a stall with no visible cause.

**`jq` is not universally present.** Recent macOS ships it; older versions don't. Degrade to a generic notification rather than failing.
