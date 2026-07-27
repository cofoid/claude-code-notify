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

# Runs on macOS and inside Linux devcontainers. Everything up to the delivery
# section is platform-neutral and runs in both: what a notification should SAY
# can only be worked out where the transcript and session files are, which for
# a container session is the container. Delivery is where the platforms split —
# see the guard down there. An unguarded osascript call on Linux would error on
# every single turn, so nothing above may reach for one.

payload=$(cat)

# --- defaults ---------------------------------------------------------------

# Note: the settings that belong to delivery rather than to wording — TERM_APP,
# CLICK_TIMEOUT, IGNORE_DND, ALERTER — live in alert.sh, which sources the same
# notify.conf. They are meaningless in a container, where nothing is delivered.
SOUND_STOP="Hero"
SOUND_NOTIFICATION="Funk"
GROUP_MODE="unique"
BODY_LENGTH="140"

# Recover what is actually being asked from the transcript. Set to "0" to
# always show neutral wording instead.
DESCRIBE_REQUEST="1"

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
GROUP_MODE="${CLAUDE_NOTIFY_GROUP_MODE:-$GROUP_MODE}"
BODY_LENGTH="${CLAUDE_NOTIFY_BODY_LENGTH:-$BODY_LENGTH}"
DESCRIBE_REQUEST="${CLAUDE_NOTIFY_DESCRIBE_REQUEST:-$DESCRIBE_REQUEST}"
DESCRIBER="$(dirname "$0")/describe-request.py"
ALERT="$(dirname "$0")/alert.sh"
SPOOL="${CLAUDE_NOTIFY_SPOOL:-$HOME/.claude/notify-spool.jsonl}"

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
    # .message is generic and never names the tool, so try to recover the actual
    # pending request from the transcript. The describer only reports a tool
    # whose tool_result is still missing — a completed call is not what you are
    # being asked about, and naming it would be confidently wrong. When it can't
    # tell, it prints nothing and we fall back to neutral wording.
    detail=""
    if [ "$DESCRIBE_REQUEST" != "0" ] && [ -n "$tpath" ] && [ -f "$tpath" ] \
       && [ -f "$DESCRIBER" ] && command -v python3 >/dev/null 2>&1; then
      detail=$(python3 "$DESCRIBER" "$tpath" 2>/dev/null)
    fi
    if [ -n "$detail" ]; then
      msg=$(summarize "$detail")
    elif [ -n "$MESSAGE_ATTENTION" ] && [ "$ntype" = "permission_prompt" ]; then
      # .message says "Claude needs your permission" even for a question box,
      # so passing it through mislabels every question as a permission request.
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
# Not macOS: this is a devcontainer, which has no Notification Center to post
# to and no route to the host's. But the container's ~/.claude IS a host
# directory — the bind mount that carries the credentials — so the mount is the
# delivery channel. No network, no SSH, no daemon in the container.
#
# The notification is already finished by this point, which is deliberate: the
# host watcher never sees a transcript path or a session file, both of which
# name paths that only exist inside the container.
#
# ONE \n-terminated line, appended. Concurrent container sessions share this
# file, and a single small append is what keeps their writes from interleaving.
if [ "$(uname)" != "Darwin" ]; then
  if command -v jq >/dev/null 2>&1; then
    jq -cn \
      --arg title "$title" --arg subtitle "$subtitle" --arg message "$msg" \
      --arg sound "$sound" --arg group "$group" \
      --arg name "$session_name" --arg cwd "$cwd" \
      '{$title, $subtitle, $message, $sound, $group, $name, $cwd}' >> "$SPOOL"
  else
    # Say so rather than exiting 0 into silence: a container without jq has
    # already produced an empty-field notification, and no delivery at all is
    # the kind of failure that reads as "the hook never fired".
    echo "claude-code-notify: jq not found in container — notification dropped" >&2
  fi
  exit 0
fi

exec "$ALERT" "$title" "$subtitle" "$msg" "$sound" "$group" "$session_name" "$cwd"
