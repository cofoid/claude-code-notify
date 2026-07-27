#!/bin/sh
# claude-code-notify — rich macOS notifications for Claude Code.
#
# Wired to the Stop and Notification hooks in ~/.claude/settings.json.
# Reads the hook payload as JSON on stdin; $1 is the sound name.
#
# Configuration (environment variables, set in settings.json if you want):
#   CLAUDE_NOTIFY_TERM_APP   Terminal app to focus on click.  Default: Ghostty
#   CLAUDE_NOTIFY_TIMEOUT    Seconds to listen for a click.   Default: 45
#   CLAUDE_NOTIFY_ALERTER    Path to the alerter binary.      Default: ~/.local/bin/alerter

# macOS-only. Exit quietly elsewhere: this same settings.json is read by Linux
# devcontainers that mount the repo, and an unguarded osascript call errors on
# every turn there.
[ "$(uname)" = "Darwin" ] || exit 0

payload=$(cat)
sound="${1:-Funk}"

TERM_APP="${CLAUDE_NOTIFY_TERM_APP:-Ghostty}"
CLICK_TIMEOUT="${CLAUDE_NOTIFY_TIMEOUT:-45}"
ALERTER="${CLAUDE_NOTIFY_ALERTER:-$HOME/.local/bin/alerter}"
SCPT="$(dirname "$0")/focus-ghostty.applescript"

# Character- rather than byte-oriented truncation, so clipping can't slice a
# multi-byte glyph in half and produce mojibake in the banner.
LC_ALL="${LC_ALL:-en_US.UTF-8}"
export LC_ALL

# jq is required for payload parsing. Without it every field comes back empty and
# the notification degrades to a generic alert rather than failing outright.
field() { printf '%s' "$payload" | jq -r "$1 // empty" 2>/dev/null; }

# Collapse to one line and clip — notification bodies are truncated by the OS
# anyway, and embedded newlines/markdown read as noise in a banner.
summarize() {
  printf '%s' "$1" \
    | tr '\n' ' ' \
    | sed -e 's/`//g' -e 's/\*\*//g' -e 's/  */ /g' -e 's/^ *//' \
    | cut -c1-140
}

event=$(field '.hook_event_name')
msg=$(field '.message')
cwd=$(field '.cwd')
sid=$(field '.session_id')
ntype=$(field '.notification_type')
last_msg=$(field '.last_assistant_message')
tpath=$(field '.transcript_path')

# /color is not stored in the session file or settings — it lands in the
# transcript as {"type":"agent-color","agentColor":"..."} entries, re-emitted
# each turn, so the last one wins. Tail a bounded slice: transcripts reach tens
# of MB in long sessions and this runs on every turn.
agent_color=""
if [ -n "$tpath" ] && [ -f "$tpath" ]; then
  agent_color=$(tail -c 200000 "$tpath" 2>/dev/null \
    | grep -o '"agentColor":"[a-zA-Z]*"' \
    | tail -1 \
    | sed -e 's/.*:"//' -e 's/"$//')
fi

# Claude Code offers exactly 8 colours: red, blue, green, yellow, purple,
# orange, pink, cyan. "gray"/"grey"/"default"/"none"/"reset" are reset aliases,
# not colours, so they correctly yield no glyph. Six map to an exact square;
# pink and cyan have no square in Unicode and use the matching heart — a single
# glyph beats a two-glyph blend, since the title already carries an event icon.
case "$agent_color" in
  red)    square="🟥" ;;
  blue)   square="🟦" ;;
  green)  square="🟩" ;;
  yellow) square="🟨" ;;
  purple) square="🟪" ;;
  orange) square="🟧" ;;
  pink)   square="🩷" ;;
  cyan)   square="🩵" ;;
  *)      square="" ;;
esac

project=$(basename "${cwd:-$PWD}")
short_sid=$(printf '%s' "$sid" | cut -c1-8)

# /rename writes the session name to ~/.claude/sessions/<pid>.json keyed by
# sessionId — the hook payload has no name field. Files are per-pid, so scan
# them all and match on sessionId rather than guessing a filename.
session_name=""
if [ -n "$sid" ]; then
  session_name=$(jq -r --arg sid "$sid" \
    'select(.sessionId == $sid) | .name // empty' \
    "$HOME"/.claude/sessions/*.json 2>/dev/null | head -1)
fi
label="${session_name:-$short_sid}"

case "$event" in
  Stop)
    icon="✅"
    subtitle="Task complete"
    # .message is always null on Stop; the useful content is the tail of what
    # Claude just said, which tells you what finished without switching windows.
    msg=$(summarize "$last_msg")
    [ -n "$msg" ] || msg="Turn finished — ready for input"
    ;;
  Notification)
    # .notification_type is the authoritative classifier; .message is generic
    # ("Claude needs your permission") and never names the tool.
    case "$ntype" in
      permission_prompt) icon="🔐"; subtitle="Permission needed" ;;
      idle*|*timeout*)   icon="⏳"; subtitle="Waiting on you" ;;
      "")                icon="💬"; subtitle="Needs your input" ;;
      *)                 icon="💬"; subtitle="$ntype" ;;
    esac
    msg=$(summarize "$msg")
    [ -n "$msg" ] || msg="Claude needs your attention"
    ;;
  *)
    icon="🔔"
    subtitle="${event:-Claude Code}"
    msg=$(summarize "$msg")
    [ -n "$msg" ] || msg="Claude Code alert"
    ;;
esac

title="${square:+$square }$icon $project"
[ -n "$label" ] && subtitle="$label · $subtitle"

# --- delivery ---------------------------------------------------------------
#
# alerter (UNUserNotificationCenter, notarized) is the preferred path: it is the
# only one that delivers on current macOS AND reports clicks. It BLOCKS while
# waiting for a click — that is how it emits @CONTENTCLICKED — so it must run
# detached or it stalls the hook for the whole timeout.
#
# python3 is required for the detach (fork + setsid). Both must be present, or
# we fall through to osascript: taking this branch without python3 would exit 0
# and deliver nothing at all.
#
# Do NOT pass --sender to impersonate the terminal's bundle id: alerter hangs.
if [ -x "$ALERTER" ] && command -v python3 >/dev/null 2>&1; then
  # A plain background subshell is NOT enough — Claude Code reaps the hook's
  # process group, which kills the click listener. fork + setsid puts it in its
  # own session so it outlives the hook.
  A="$ALERTER" T="$title" S="$subtitle" M="$msg" SND="$sound" \
  G="claude-${sid:-default}" NAME="$session_name" CWD="$cwd" \
  SCPT="$SCPT" APP="$TERM_APP" TMO="$CLICK_TIMEOUT" python3 -c '
import os, sys, subprocess
if os.fork() > 0:
    sys.exit(0)          # hook returns immediately
os.setsid()              # escape the process group Claude Code reaps
e = os.environ
out = subprocess.run(
    [e["A"], "--title", e["T"], "--subtitle", e["S"], "--message", e["M"],
     "--sound", e["SND"], "--group", e["G"], "--timeout", e["TMO"]],
    capture_output=True, text=True,
).stdout
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
# a quote or backslash in .message would otherwise break it or inject.
osascript - "$title" "$subtitle" "$msg" "$sound" <<'APPLESCRIPT'
on run argv
  display notification (item 3 of argv) ¬
    with title (item 1 of argv) ¬
    subtitle (item 2 of argv) ¬
    sound name (item 4 of argv)
end run
APPLESCRIPT
