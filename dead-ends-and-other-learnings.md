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

### Terminal notification escape sequences are not a substitute for alerter

Ghostty supports both `OSC 777` and `OSC 9`, which would be a tempting way to
notify over SSH: the pty is already there, so no tunnel, no listener, nothing to
install. Written to the pty resolved via `$PPID` (see above) both sequences
succeed — exit 0, no error — and **neither renders a banner while the surface is
focused**, which is exactly when a hook fires.

Even where they do render, they carry no click-reporting channel, no sound
selection and no group identity, so the whole click-through-to-the-right-tab
feature would be gone. Not a shortcut worth taking.

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

### A question box and a tool-permission prompt are indistinguishable

`AskUserQuestion` (the multiple-choice picker) and a tool approval both arrive as `notification_type: "permission_prompt"` with `message: "Claude needs your permission"`. The payloads are byte-identical — verified by capturing both. There is no field to branch on, so a single label has to cover both cases. Don't write "Permission needed" and assume it's accurate; it will be wrong every time Claude asks you a question.

Note also that `AskUserQuestion` *does* fire the `Notification` hook, which isn't obvious — it's easy to conclude the hook is broken when testing with a picker, because early docs suggest only permission prompts and idle timeouts trigger it.

### Naming the pending tool works — but only with a `tool_result` check

The obvious workaround for the generic `message` is to read the last `tool_use` from the transcript and show *that*: "Write: /path/to/file". Done naively it is wrong often enough to be dangerous — the newest `tool_use` is frequently the *previous*, already-completed call, so the banner confidently names a tool that isn't the one waiting on you.

Observed: a question box produced `Edit: /Users/…/notify.conf`, the edit made seven seconds earlier.

**The discriminator is `tool_result`.** Every completed call has one recorded against its `tool_use` id; a call blocked waiting on you does not. So take the newest `tool_use` and describe it *only if its id has no matching `tool_result`*. Otherwise print nothing.

That single check turns an unreliable feature into a correct one:

- **Tool permission prompts** — the `tool_use` is written and unresolved when the prompt appears, so the banner names the actual pending tool and its target. Verified: a blocked `Write` produced `Write: /Users/…/claude-notify-describer-test.txt`.
- **Question boxes** — `AskUserQuestion` does not reach the transcript before the hook fires, so the newest entry is a resolved call, the check suppresses it, and the banner falls back to neutral wording. Verified.

The asymmetry is a genuine race, not a fixable lag — a sleep won't help, because the `Notification` hook already fires seconds late and the data still isn't there. Design for it: show detail when you can prove it's pending, neutral text when you can't. A wrong tool name is worse than no tool name, because it's specific, plausible, and believed.

### The subtitle truncates around 40 characters

`<session name> · <label>` is the natural subtitle, but macOS clips it. "Awaiting your response" became "Awaiting your res…" behind a 21-character session name.

Keep event labels to a word or two — "Done", "Needs you", "Waiting". The icon already carries the event type, so the words only need to disambiguate, and the session name is the part you actually need to read.

### Grouping can swallow notifications silently

`--group` replaces an existing banner with the same id, which is appealing for keeping Notification Center tidy. But when the earlier banner is still on screen — likely if you've set the persistent Alerts style — the replacement updates it **in place, without re-alerting**. No sound, no new banner. You simply don't find out.

Observed in practice while testing: a notification appeared to fail entirely, when in fact it had quietly replaced its predecessor. Prefer a unique group per notification unless you have a specific reason to coalesce.

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

### A banner has two clickable parts and they report differently

`alerter` writes a token to stdout when the notification is resolved. Clicking
the banner **body** emits `@CONTENTCLICKED` — but clicking the **"Show" button**
emits `@ACTIONCLICKED`, and the obvious guard only tests for the first:

```python
if "CONTENTCLICKED" not in out:
    sys.exit(0)
```

That leaves "Show" dead. It dismisses the banner and focuses nothing, which
presents as click-through being broken in general rather than as one token going
unhandled — especially since clicking the body still works, so the same feature
looks intermittent depending on where the pointer happened to land.

Test both tokens (`@TIMEOUT` and `@CLOSED` are the not-a-click cases). Verified
by capturing alerter's stdout to a file and clicking "Show": `STDOUT=
'@ACTIONCLICKED'`, with the focus call that followed returning `focused:title`
once it was allowed to run.

## Timing

`Stop` fires essentially instantly. `Notification` lags **1.5–6 seconds**, and the lag is variable rather than a fixed cost.

That delay is in Claude Code's hook dispatch, not in delivery. The proof: fire a local terminal bell and a Notification Center banner from the same hook. They share no downstream machinery, and both arrive late together — so the delay is upstream of both. No change to the notification tooling will fix it. Don't spend time on it.

## Devcontainers

### launchd throttles any job to one spawn per ten seconds — `WatchPaths` included

The obvious way to drain a spool file is a launchd agent with `WatchPaths` on it
and a short `StartInterval` as a backstop. Measured end to end, a line appended
to the spool took **9.4s, 10.3s and 10.4s** to post across three trials, with
`StartInterval` set to 5.

Neither trigger is broken. launchd refuses to respawn a job more often than
every ten seconds, and that ceiling applies to `WatchPaths` and `StartInterval`
alike — asking twice does not get you served sooner. Ten seconds is a long time
to sit next to a terminal that is waiting on you.

**Use instead:** stay resident. `KeepAlive` with a one-second poll inside the
process is not throttled, measured at 0.06–1.44s, and the process is asleep
between polls. It also retires a question you would otherwise have to answer:
whether a write arriving through a Docker bind mount raises an FSEvent on the
host at all. Polling never asks.

### A container's session name does reach the host terminal title

Whether click-to-tab could work for a container session was genuinely unclear —
the session name lives in the container's `~/.claude/sessions/*.json`, and the
Ghostty surface being matched is a host window several boundaries away.

It works, and the reason is that Claude Code sets the title with an escape
sequence, which is just bytes on the terminal stream and crosses `docker exec`
untouched. Verified by listing every Ghostty surface title and intersecting it
with both session directories: `B - Grain`, `B1a - Diff to prod` and
`B2 - Investigate ProductID Fix` appeared as host tab titles while existing
*only* in the container's session files. `focus <terminal>` on that surface then
returned `focused:title` as it does for a host session.

The caveat is the transport, not the container: this holds when Claude runs in a
terminal tab. An editor's integrated terminal is not a Ghostty surface and
cannot be focused this way.

The working-directory fallback, though, is inert across the boundary — the
payload's `cwd` is `/workspaces/...` and no host tab will ever report that. It
fails closed rather than wrong, because the fallback only accepts a *unique*
match and there are zero.

### The spool is the mount, and the mount ignores the container's chown

A devcontainer that bind-mounts the host's credential directory usually runs
`chown -R node:node` over it in `postStartCommand`. That looks like it should
leave the host unable to read its own files. It doesn't: Docker Desktop's bind
mounts don't propagate ownership back, and the host files stay owned by the host
user — confirmed by `ls -la` on a credential directory that had been chowned
inside a container many times.

Worth checking on your own setup before relying on it, because if ownership
*did* propagate, the host watcher would lose its own spool on the next container
start.

## SSH sessions

### The socket's own permissions are the wrong control — the directory is the right one

A forwarded socket is a channel into your Notification Center from another
machine, so it is worth locking down. Three separate reasons not to rely on the
socket's own mode:

- OpenSSH already defaults `StreamLocalBindMask` to `0177`, i.e. `0600` — but for
  a `RemoteForward` the socket is created by the **remote** `sshd`, so it is the
  remote's config that decides and nothing on the client can guarantee it.
- `ssh_config(5)` says outright: *"not all operating systems honor the file mode
  on Unix-domain socket files."*
- On the Mac side ssh isn't creating it at all — `notify-watch.py` is — and
  Python's `bind()` honours the umask, which is `0755` in practice.

A `0700` parent directory is enforced everywhere and covers all three. Both ends
create `~/.claude/notify.d` with that mode; the `0600` on the socket is a second
layer, not the mechanism.

### `RemoteForward` does not expand `~`

Both paths must be absolute, which means the setup step has to look up the
remote `$HOME` (`ssh host 'printf %s "$HOME"'`) rather than print a `~` and hope.

### A dropped connection leaves the socket behind and blocks the next one

`bind()` on an existing path fails with `EADDRINUSE`, so an unclean disconnect
breaks the *following* connection rather than the one that failed. `ssh` needs
`StreamLocalBindUnlink yes`, honoured by whichever end creates the socket — so if
forwarding still fails with "remote port forwarding failed", it is the remote's
`sshd_config` that needs it. The watcher unlinks its own stale socket before
binding for the same reason.

## Environment gotchas

**Guard for macOS.** A `settings.json` at `~/.claude/` is read by Linux devcontainers too. An unguarded `osascript` call errors on every single turn in a container. `[ "$(uname)" = "Darwin" ] || exit 0`.

**Check your interpreters exist before branching on them.** If a delivery path needs `python3` and it's missing, a branch that takes the path and then `exit 0`s skips the fallback and delivers nothing, silently. On a Mac without Command Line Tools, `/usr/bin/python3` is a stub that *hangs* prompting to install them — inside a hook, that's a stall with no visible cause.

**`jq` is not universally present.** Recent macOS ships it; older versions don't. Degrade to a generic notification rather than failing.
