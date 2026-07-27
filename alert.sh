#!/bin/sh
# claude-code-notify — deliver one finished notification on macOS.
#
#   alert.sh <title> <subtitle> <message> <sound> <group> <session-name> <cwd>
#
# Everything is already decided by the caller; this only delivers. Two callers
# share it, which is the point: notify.sh for host sessions, notify-watch.py
# for sessions running inside a devcontainer, whose payloads arrive by spool
# file. A second copy of the alerter invocation would drift from this one.
#
# Reads the same ~/.claude/hooks/notify.conf as notify.sh, for the settings
# that belong to delivery rather than to wording.

[ "$(uname)" = "Darwin" ] || exit 0

title="$1"; subtitle="$2"; msg="$3"; sound="$4"
group="$5"; session_name="$6"; cwd="$7"

TERM_APP="Ghostty"
CLICK_TIMEOUT="45"
# Focus/Do Not Disturb silently suppresses notifications, which looks exactly
# like a broken hook. You opted into these alerts, so they bypass it by default.
IGNORE_DND="1"

CONF="${CLAUDE_NOTIFY_CONF:-$HOME/.claude/hooks/notify.conf}"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"

# Environment overrides win over the config file.
TERM_APP="${CLAUDE_NOTIFY_TERM_APP:-$TERM_APP}"
CLICK_TIMEOUT="${CLAUDE_NOTIFY_TIMEOUT:-$CLICK_TIMEOUT}"
IGNORE_DND="${CLAUDE_NOTIFY_IGNORE_DND:-$IGNORE_DND}"
ALERTER="${CLAUDE_NOTIFY_ALERTER:-$HOME/.local/bin/alerter}"
SCPT="$(dirname "$0")/focus-ghostty.applescript"

# alerter (UNUserNotificationCenter, notarized) is the preferred path: the only
# one that delivers on current macOS AND reports clicks. It BLOCKS while waiting
# for a click — that is how it emits @CONTENTCLICKED — so it must run detached
# or it stalls the caller for the whole timeout.
#
# python3 is required for the detach (fork + setsid). Both must be present, or
# we fall through to osascript: taking this branch without python3 would exit 0
# and deliver nothing at all.
#
# Do NOT pass --sender to impersonate the terminal's bundle id: alerter hangs.
if [ -x "$ALERTER" ] && command -v python3 >/dev/null 2>&1; then
  # A plain background subshell is NOT enough when the caller is a hook: Claude
  # Code reaps the hook's process group, which kills the click listener.
  # fork + setsid puts it in its own session so it outlives the caller.
  A="$ALERTER" T="$title" S="$subtitle" M="$msg" SND="$sound" \
  G="$group" NAME="$session_name" CWD="$cwd" DND="$IGNORE_DND" \
  SCPT="$SCPT" APP="$TERM_APP" TMO="$CLICK_TIMEOUT" python3 -c '
import os, sys, subprocess
if os.fork() > 0:
    sys.exit(0)          # caller returns immediately
os.setsid()              # escape the process group Claude Code reaps
e = os.environ
cmd = [e["A"], "--title", e["T"], "--subtitle", e["S"], "--message", e["M"],
       "--group", e["G"], "--timeout", e["TMO"]]
if e.get("SND"):
    cmd += ["--sound", e["SND"]]
if e.get("DND") == "1":
    cmd += ["--ignore-dnd"]
out = subprocess.run(cmd, capture_output=True, text=True).stdout
if "CONTENTCLICKED" not in out:
    sys.exit(0)
# Ghostty exposes an AppleScript dictionary, so the click can land on the exact
# tab. Any other terminal falls back to app-level activation.
focused = False
if e["APP"] == "Ghostty" and os.path.exists(e["SCPT"]):
    r = subprocess.run(["osascript", e["SCPT"], e.get("NAME", ""), e.get("CWD", "")],
                       capture_output=True, text=True)
    focused = "focused:" in r.stdout
if not focused:
    subprocess.run(["open", "-a", e["APP"]])
' >/dev/null 2>&1
  exit 0
fi

# Fallback: no alerter (or no python3). Delivers reliably, but posts under
# Script Editor, so clicking opens Script Editor rather than your terminal.
# Pass strings as argv rather than interpolating into the AppleScript source —
# a quote or backslash in the message would otherwise break it or inject.
osascript - "$title" "$subtitle" "$msg" "${sound:-Funk}" <<'APPLESCRIPT'
on run argv
  display notification (item 3 of argv) ¬
    with title (item 1 of argv) ¬
    subtitle (item 2 of argv) ¬
    sound name (item 4 of argv)
end run
APPLESCRIPT
