#!/bin/sh
# claude-code-notify installer.
#
#   ./install.sh                      install / update, for host sessions
#   ./install.sh --container <dir>    install into a devcontainer's bind-mounted
#                                     ~/.claude (give the HOST path of it)
#   ./install.sh --watch <dir> [...]  launchd agent that posts what those
#                                     containers spool
#   ./install.sh --uninstall          remove hook files and the agent
#
# Idempotent: safe to re-run. Never edits settings.json for you — it prints the
# snippet to paste, because settings.json commonly holds hand-tuned permissions
# and hooks that an automated edit could clobber. That goes for a container's
# settings.json too, which is a real file in the bind-mounted credential dir.

set -e

HOOK_DIR="$HOME/.claude/hooks"
BIN_DIR="$HOME/.local/bin"
SRC_DIR=$(cd "$(dirname "$0")" && pwd)
ALERTER_REPO="vjeantet/alerter"
AGENT_LABEL="com.claude-code-notify.watch"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
LOG_DIR="$HOME/Library/Logs/claude-code-notify"
SPOOL_NAME="notify-spool.jsonl"

red()  { printf '\033[31m%s\033[0m\n' "$1"; }
grn()  { printf '\033[32m%s\033[0m\n' "$1"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$1"; }

if [ "$1" = "--uninstall" ]; then
  if [ -f "$AGENT_PLIST" ]; then
    launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
    rm -f "$AGENT_PLIST"
    grn "Removed the watcher agent"
  fi
  rm -f "$HOOK_DIR/notify.sh" "$HOOK_DIR/alert.sh" \
        "$HOOK_DIR/focus-ghostty.applescript" "$HOOK_DIR/describe-request.py" \
        "$HOOK_DIR/notify-watch.py"
  grn "Removed hook files from $HOOK_DIR"
  ylw "Remove the Stop and Notification entries from ~/.claude/settings.json by hand."
  ylw "Container installs (--container) are left alone; remove those dirs yourself."
  ylw "The alerter binary at $BIN_DIR/alerter was left in place."
  exit 0
fi

# --- container install ------------------------------------------------------
#
# A devcontainer session cannot post a notification and cannot reach the host's
# Notification Center. But its ~/.claude is bind-mounted from a host directory,
# so notify.sh runs in the container, works out what the notification should
# say, and appends it to a spool there. Nothing is installed *into* the image —
# the credential dir the container already mounts is the whole channel.
#
# Takes the HOST path of that directory, e.g.
#   ./install.sh --container ~/.ncd-devcontainer/claude

if [ "$1" = "--container" ]; then
  dir="$2"
  [ -n "$dir" ] || { red "Usage: install.sh --container <host path of the container's ~/.claude>"; exit 1; }
  [ -d "$dir" ] || { red "No such directory: $dir"; exit 1; }

  mkdir -p "$dir/hooks"
  cp "$SRC_DIR/notify.sh" "$dir/hooks/notify.sh"
  cp "$SRC_DIR/describe-request.py" "$dir/hooks/describe-request.py"
  chmod +x "$dir/hooks/notify.sh" "$dir/hooks/describe-request.py"
  # alert.sh and the AppleScript are macOS-only and deliberately not copied:
  # nothing in the container has anything to deliver to.
  if [ -f "$dir/hooks/notify.conf" ]; then
    ylw "Kept the existing config at $dir/hooks/notify.conf"
  else
    cp "$SRC_DIR/notify.conf.example" "$dir/hooks/notify.conf"
    grn "Created config at $dir/hooks/notify.conf"
  fi
  # Create the spool now: launchd WatchPaths on a path that does not exist falls
  # back to watching its parent directory, which in a Claude credential dir is
  # rewritten constantly and would wake the watcher for no reason.
  [ -f "$dir/$SPOOL_NAME" ] || : > "$dir/$SPOOL_NAME"
  grn "Installed container hook files to $dir/hooks"

  cat <<EOF

------------------------------------------------------------------------
Add this to $dir/settings.json — that file is the container's
~/.claude/settings.json, so \$HOME resolves inside the container:

  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command",
                     "command": "\$HOME/.claude/hooks/notify.sh" } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "command",
                     "command": "\$HOME/.claude/hooks/notify.sh" } ] }
    ]
  }

The container needs jq (payload parsing) and python3 (naming the pending
tool). Add jq to the devcontainer's postCreateCommand if it is missing —
without it the notification still posts, but with no content in it.

Then register the spool with the host watcher:

  ./install.sh --watch $dir [<other container dirs> ...]
------------------------------------------------------------------------

EOF
  exit 0
fi

# --- watcher agent ----------------------------------------------------------
#
# One resident launchd agent drains every container spool, polling once a
# second. The obvious design — WatchPaths on the spools, StartInterval as a
# backstop — was built first and measured at 9.4–10.4s to deliver, because
# launchd throttles any job to one spawn per ten seconds and that ceiling
# applies to both triggers. Staying resident sidesteps the throttle, and means
# nothing depends on whether a write through a Docker bind mount raises a host
# FSEvent — a question this never has to answer.

if [ "$1" = "--watch" ]; then
  shift
  [ $# -gt 0 ] || { red "Usage: install.sh --watch <container ~/.claude dir> [...]"; exit 1; }

  mkdir -p "$HOOK_DIR" "$LOG_DIR" "$HOME/Library/LaunchAgents"
  cp "$SRC_DIR/notify-watch.py" "$HOOK_DIR/notify-watch.py"
  chmod +x "$HOOK_DIR/notify-watch.py"

  spools=""
  for dir in "$@"; do
    [ -d "$dir" ] || { red "No such directory: $dir"; exit 1; }
    [ -f "$dir/$SPOOL_NAME" ] || : > "$dir/$SPOOL_NAME"
    spools="$spools
        <string>$dir/$SPOOL_NAME</string>"
  done

  cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HOOK_DIR/notify-watch.py</string>
        <string>--interval</string>
        <string>1</string>$spools
    </array>
    <!-- Resident, not periodic: launchd will not respawn a job more than once
         every ten seconds, which made a StartInterval/WatchPaths version take
         ~10s to deliver. A poll from inside the process has no such ceiling.
         A run with nothing new is one stat per spool. -->
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <!-- Low priority: this spends its life asleep and must never compete with
         whatever is actually running. -->
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/watch.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/watch.log</string>
</dict>
</plist>
EOF

  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
  grn "Watcher agent loaded — draining:"
  for dir in "$@"; do echo "  $dir/$SPOOL_NAME"; done
  echo "Log: $LOG_DIR/watch.log"
  exit 0
fi

# --- preflight --------------------------------------------------------------

[ "$(uname)" = "Darwin" ] || { red "macOS only — this uses Notification Center."; exit 1; }

missing=""
command -v jq      >/dev/null 2>&1 || missing="$missing jq"
command -v python3 >/dev/null 2>&1 || missing="$missing python3"

if [ -n "$missing" ]; then
  red "Missing required tools:$missing"
  echo "  jq      — payload parsing        (brew install jq)"
  echo "  python3 — detaches the click listener; without it clicks do nothing"
  echo "            (xcode-select --install, or brew install python)"
  exit 1
fi

# --- alerter ----------------------------------------------------------------
#
# Delivery depends on alerter. terminal-notifier does NOT work on current macOS:
# it is built on NSUserNotification (deprecated in 10.14, no longer delivered),
# exits 0, and silently posts nothing. alerter is a Swift rewrite on
# UNUserNotificationCenter. It is not in Homebrew and the vjeantet/alerter tap
# does not exist, so install from the signed GitHub release.

if [ -x "$BIN_DIR/alerter" ]; then
  grn "alerter already installed at $BIN_DIR/alerter"
else
  echo "Installing alerter from github.com/$ALERTER_REPO ..."
  mkdir -p "$BIN_DIR"
  tmp=$(mktemp -d)
  url=$(curl -sL "https://api.github.com/repos/$ALERTER_REPO/releases/latest" \
        | jq -r '.assets[] | select(.name|endswith(".zip")) | .browser_download_url' | head -1)
  [ -n "$url" ] || { red "Could not resolve the alerter release URL."; exit 1; }
  curl -sL -o "$tmp/alerter.zip" "$url"
  unzip -o -q "$tmp/alerter.zip" -d "$tmp"
  bin=$(find "$tmp" -type f -name 'alerter*' ! -name '*.zip' | head -1)
  [ -n "$bin" ] || { red "No alerter binary in the release archive."; exit 1; }

  # Verify the signature before trusting it. Refuse rather than install blind.
  if ! spctl -a -vv -t install "$bin" 2>&1 | grep -q "accepted"; then
    red "alerter failed Gatekeeper verification — refusing to install."
    exit 1
  fi
  grn "Signature verified (notarized Developer ID)."

  cp "$bin" "$BIN_DIR/alerter"
  chmod +x "$BIN_DIR/alerter"
  xattr -d com.apple.quarantine "$BIN_DIR/alerter" 2>/dev/null || true
  rm -rf "$tmp"
  grn "Installed alerter to $BIN_DIR/alerter"
fi

# --- hook files -------------------------------------------------------------

mkdir -p "$HOOK_DIR"
cp "$SRC_DIR/notify.sh" "$HOOK_DIR/notify.sh"
cp "$SRC_DIR/alert.sh" "$HOOK_DIR/alert.sh"
cp "$SRC_DIR/focus-ghostty.applescript" "$HOOK_DIR/focus-ghostty.applescript"
cp "$SRC_DIR/describe-request.py" "$HOOK_DIR/describe-request.py"
chmod +x "$HOOK_DIR/notify.sh" "$HOOK_DIR/alert.sh" "$HOOK_DIR/describe-request.py"
grn "Installed hook files to $HOOK_DIR"

# Never overwrite an existing config — that would silently discard the user's
# sound and glyph choices on every update.
if [ -f "$HOOK_DIR/notify.conf" ]; then
  ylw "Kept your existing config at $HOOK_DIR/notify.conf"
  ylw "(compare against notify.conf.example for any new options)"
else
  cp "$SRC_DIR/notify.conf.example" "$HOOK_DIR/notify.conf"
  grn "Created config at $HOOK_DIR/notify.conf — edit to change sounds and glyphs"
fi

# --- settings snippet -------------------------------------------------------

cat <<'EOF'

------------------------------------------------------------------------
Add this to ~/.claude/settings.json (merge into an existing "hooks" block
if you already have one), then restart Claude Code:

  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command",
                     "command": "$HOME/.claude/hooks/notify.sh" } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "command",
                     "command": "$HOME/.claude/hooks/notify.sh" } ] }
    ]
  }

Sounds, glyphs, and click behaviour are set in notify.conf — not here.
------------------------------------------------------------------------

First notification will raise a macOS permission prompt for alerter, and
clicking one will raise a second prompt to control your terminal. Approve
both. Then set alerter to persistent banners:

  System Settings > Notifications > alerter > Alert style > Alerts

EOF

grn "Done."
