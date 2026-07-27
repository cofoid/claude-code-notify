#!/bin/sh
# claude-code-notify — rich macOS notifications for Claude Code.
#
# Wired to the Stop and Notification hooks in ~/.claude/settings.json.
# Reads the hook payload as JSON on stdin.
#
# Configuration: ~/.claude/hooks/notify.conf (see notify.conf.example).
# Precedence: defaults < config file < CLAUDE_NOTIFY_* environment variables.
#
# An optional first argument overrides the sound for this invocation, kept for
# backwards compatibility with installs that pass it from settings.json.

# macOS-only. Exit quietly elsewhere: this same settings.json is read by Linux
# devcontainers that mount the repo, and an unguarded osascript call would error
# on every turn there.
[ "$(uname)" = "Darwin" ] || exit 0

payload=$(cat)

# --- defaults ---------------------------------------------------------------

SOUND_STOP="Hero"
SOUND_NOTIFICATION="Funk"
TERM_APP="Ghostty"
CLICK_TIMEOUT="45"
GROUP_MODE="unique"
BODY_LENGTH="140"
# Focus/Do Not Disturb silently suppresses notifications, which looks exactly
# like a broken hook. You opted into these alerts, so they bypass it by default.
IGNORE_DND="1"

ICON_STOP="✅"
ICON_ATTENTION="⏸️"
ICON_WAITING="⏳"
ICON_GENERIC="🔔"

# Kept short on purpose: the subtitle is "<session name> · <label>" and macOS
# truncates it around 40 characters. The icon already carries the event type,
# so the words only need to disambiguate.
LABEL_STOP="Done"
LABEL_ATTENTION="Needs you"
LABEL_WAITING="Waiting"

# Body text for attention events. Deliberately neutral: the payload says
# "Claude needs your permission" even when Claude is only asking a question,
# which reads as a permission request and is misleading. Set to "" to pass the
# payload's own wording through instead.
MESSAGE_ATTENTION="Waiting for your response in the terminal"

COLOR_RED="🟥"
COLOR_BLUE="🟦"
COLOR_GREEN="🟩"
COLOR_YELLOW="🟨"
COLOR_PURPLE="🟪"
COLOR_ORANGE="🟧"
COLOR_PINK="🩷"
COLOR_CYAN="🩵"

CONF="${CLAUDE_NOTIFY_CONF:-$HOME/.claude/hooks/notify.conf}"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"

# Environment overrides win over the config file.
TERM_APP="${CLAUDE_NOTIFY_TERM_APP:-$TERM_APP}"
CLICK_TIMEOUT="${CLAUDE_NOTIFY_TIMEOUT:-$CLICK_TIMEOUT}"
GROUP_MODE="${CLAUDE_NOTIFY_GROUP_MODE:-$GROUP_MODE}"
BODY_LENGTH="${CLAUDE_NOTIFY_BODY_LENGTH:-$BODY_LENGTH}"
IGNORE_DND="${CLAUDE_NOTIFY_IGNORE_DND:-$IGNORE_DND}"
ALERTER="${CLAUDE_NOTIFY_ALERTER:-$HOME/.local/bin/alerter}"
SCPT="$(dirname "$0")/focus-ghostty.applescript"

# Character- rather than byte-oriented truncation, so clipping can't slice a
# multi-byte glyph in half and produce mojibake in the banner.
LC_ALL="${LC_ALL:-en_US.UTF-8}"
export LC_ALL

# jq is required for payload parsing. Without it every field comes back empty
# and the notification degrades to a generic alert rather than failing outright.
field() { printf '%s' "$payload" | jq -r "$1 // empty" 2>/dev/null; }

# Collapse to one line and clip — notification bodies are truncated by the OS
# anyway, and embedded newlines/markdown read as noise in a banner.
summarize() {
  printf '%s' "$1" \
    | tr '\n' ' ' \
    | sed -e 's/`//g' -e 's/\*\*//g' -e 's/  */ /g' -e 's/^ *//' \
    | cut -c"1-$BODY_LENGTH"
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

# Claude Code offers exactly 8 colours. "gray"/"grey"/"default"/"none"/"reset"
# are reset aliases, not colours, so they correctly yield no glyph.
case "$agent_color" in
  red)    square="$COLOR_RED" ;;
  blue)   square="$COLOR_BLUE" ;;
  green)  square="$COLOR_GREEN" ;;
  yellow) square="$COLOR_YELLOW" ;;
  purple) square="$COLOR_PURPLE" ;;
  orange) square="$COLOR_ORANGE" ;;
  pink)   square="$COLOR_PINK" ;;
  cyan)   square="$COLOR_CYAN" ;;
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
    icon="$ICON_STOP"
    subtitle="$LABEL_STOP"
    sound="$SOUND_STOP"
    # .message is always null on Stop; the useful content is the tail of what
    # Claude just said, which tells you what finished without switching windows.
    msg=$(summarize "$last_msg")
    [ -n "$msg" ] || msg="Turn finished — ready for input"
    ;;
  Notification)
    sound="$SOUND_NOTIFICATION"
    # .notification_type is the only classifier; .message is generic and never
    # names the tool. Note that a question box (AskUserQuestion) and a tool
    # permission prompt both report "permission_prompt" with identical text —
    # there is no field that distinguishes them, so one label covers both.
    case "$ntype" in
      permission_prompt) icon="$ICON_ATTENTION"; subtitle="$LABEL_ATTENTION" ;;
      idle*|*timeout*)   icon="$ICON_WAITING";   subtitle="$LABEL_WAITING" ;;
      "")                icon="$ICON_ATTENTION"; subtitle="$LABEL_ATTENTION" ;;
      *)                 icon="$ICON_ATTENTION"; subtitle="$ntype" ;;
    esac
    # There is no way to say WHICH tool or question is pending. .message is
    # generic, and the transcript only gains the tool_use after the tool
    # completes — so at prompt time the newest entry is the PREVIOUS call.
    # Reading it names the wrong tool. See dead-ends-and-other-learnings.md.
    #
    # .message also says "Claude needs your permission" for a question box, so
    # passing it through mislabels every question as a permission request.
    if [ -n "$MESSAGE_ATTENTION" ] && [ "$ntype" = "permission_prompt" ]; then
      msg="$MESSAGE_ATTENTION"
    else
      msg=$(summarize "$msg")
    fi
    [ -n "$msg" ] || msg="Claude needs your attention"
    ;;
  *)
    icon="$ICON_GENERIC"
    subtitle="${event:-Claude Code}"
    sound="$SOUND_NOTIFICATION"
    msg=$(summarize "$msg")
    [ -n "$msg" ] || msg="Claude Code alert"
    ;;
esac

# Explicit argument still wins, for installs that pass a sound from settings.json.
sound="${1:-$sound}"

title="${square:+$square }$icon $project"
[ -n "$label" ] && subtitle="$label · $subtitle"

# "session" groups by session so a new alert replaces the previous one. That is
# tidy but can update silently when the earlier banner is still on screen, so
# "unique" gives every alert its own banner instead.
if [ "$GROUP_MODE" = "unique" ]; then
  group="claude-${sid:-default}-$(date +%s)-$$"
else
  group="claude-${sid:-default}"
fi

# --- delivery ---------------------------------------------------------------
#
# alerter (UNUserNotificationCenter, notarized) is the preferred path: the only
# one that delivers on current macOS AND reports clicks. It BLOCKS while waiting
# for a click — that is how it emits @CONTENTCLICKED — so it must run detached
# or it stalls the hook for the whole timeout.
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
  G="$group" NAME="$session_name" CWD="$cwd" DND="$IGNORE_DND" \
  SCPT="$SCPT" APP="$TERM_APP" TMO="$CLICK_TIMEOUT" python3 -c '
import os, sys, subprocess
if os.fork() > 0:
    sys.exit(0)          # hook returns immediately
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
# a quote or backslash in .message would otherwise break it or inject.
osascript - "$title" "$subtitle" "$msg" "${sound:-Funk}" <<'APPLESCRIPT'
on run argv
  display notification (item 3 of argv) ¬
    with title (item 1 of argv) ¬
    subtitle (item 2 of argv) ¬
    sound name (item 4 of argv)
end run
APPLESCRIPT
