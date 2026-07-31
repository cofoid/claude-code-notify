#!/bin/sh
# claude-code-notify installer.
#
#   ./install.sh                      install / update, for host sessions
#   ./install.sh --container <dir>    install into a devcontainer's bind-mounted
#                                     ~/.claude (give the HOST path of it)
#   ./install.sh --remote <sshhost>   install into an SSH host's ~/.claude and
#                                     print the RemoteForward line to add
#   ./install.sh --watch [<dir> ...]  launchd agent that posts what containers
#                                     spool and what SSH hosts forward
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
# Where ssh lands its RemoteForward, on both ends. Same relative path either
# side keeps the config line symmetrical and easy to read.
SOCK_DIR_REL=".claude/notify.d"
SOCK_DIR="$HOME/$SOCK_DIR_REL"

red()  { printf '\033[31m%s\033[0m\n' "$1"; }
grn()  { printf '\033[32m%s\033[0m\n' "$1"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$1"; }

# Which app a click should focus. Shipping a fixed default means everyone whose
# terminal isn't that one gets a click that activates an app they don't use, or
# nothing at all. The installer runs in the user's own terminal, so this is the
# one place the answer is reliably available.
#
# TERM_PROGRAM covers most; the ones that don't set it are recognisable by TERM.
# Empty means "no idea", which the caller reports rather than guessing.
detect_term_app() {
  app=""
  case "${TERM_PROGRAM:-}" in
    ghostty)        app="Ghostty" ;;
    iTerm.app)      app="iTerm" ;;
    Apple_Terminal) app="Terminal" ;;
    WezTerm)        app="WezTerm" ;;
    WarpTerminal)   app="Warp" ;;
    Hyper)          app="Hyper" ;;
    vscode)         app="Visual Studio Code" ;;
  esac
  if [ -z "$app" ]; then
    case "${TERM:-}" in
      xterm-kitty) app="kitty" ;;
      alacritty)   app="Alacritty" ;;
    esac
  fi
  printf '%s' "$app"
}

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
  # Only the socket, not the directory: ssh recreates the socket on the next
  # connection, and an SSH host's own hook files live on that host.
  rm -f "$SOCK_DIR/sock"
  ylw "Remove the Stop and Notification entries from ~/.claude/settings.json by hand."
  ylw "Remote installs (--remote) are left alone; remove those with their own ~/.claude."
  ylw "Also drop any RemoteForward lines from ~/.ssh/config."
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
#   ./install.sh --container ~/.myproject-devcontainer/claude

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

# --- SSH host install -------------------------------------------------------
#
# An SSH session has no shared filesystem, so the container trick does not
# apply. The connection itself is the channel: ssh forwards a unix socket into
# the remote, notify.sh writes its one JSON line into that, and the watcher on
# this Mac is listening on the other end.
#
# The socket is created by the REMOTE sshd, so its mode is set by the remote's
# StreamLocalBindMask (0600 by default) and nothing here can guarantee it.
# ssh(1) also warns that socket file modes are not honoured on every OS. So the
# control that actually holds is the 0700 directory it sits in, which is created
# here rather than left to a pasted command.

if [ "$1" = "--remote" ]; then
  host="$2"
  [ -n "$host" ] || { red "Usage: install.sh --remote <ssh host or alias>"; exit 1; }

  remote_home=$(ssh "$host" 'printf %s "$HOME"') || {
    red "Could not reach $host over ssh."; exit 1; }
  [ -n "$remote_home" ] || { red "Could not determine \$HOME on $host."; exit 1; }

  # mkdir -m applies the mode at creation; chmod after covers a dir that already
  # exists from an earlier install with a laxer umask.
  ssh "$host" "mkdir -p ~/.claude/hooks ~/$SOCK_DIR_REL \
               && chmod 700 ~/$SOCK_DIR_REL" || {
    red "Could not create the remote directories."; exit 1; }

  # alert.sh and the AppleScript stay here: the remote has nothing to deliver to.
  scp -q "$SRC_DIR/notify.sh" "$SRC_DIR/describe-request.py" \
      "$host:$remote_home/.claude/hooks/" || {
    red "Could not copy the hook files to $host."; exit 1; }
  ssh "$host" "chmod +x ~/.claude/hooks/notify.sh ~/.claude/hooks/describe-request.py"

  if ssh "$host" "[ -f ~/.claude/hooks/notify.conf ]"; then
    ylw "Kept the existing config at $host:~/.claude/hooks/notify.conf"
  else
    scp -q "$SRC_DIR/notify.conf.example" "$host:$remote_home/.claude/hooks/notify.conf"
    grn "Created config at $host:~/.claude/hooks/notify.conf"
  fi

  grn "Installed hook files to $host:~/.claude/hooks"
  printf 'Remote socket dir: %s/%s (mode %s)\n' "$host:$remote_home" "$SOCK_DIR_REL" \
    "$(ssh "$host" "stat -c %a ~/$SOCK_DIR_REL 2>/dev/null || stat -f %Lp ~/$SOCK_DIR_REL")"

  ssh "$host" 'command -v jq >/dev/null 2>&1' \
    || ylw "jq is missing on $host — notifications will post with empty fields."
  ssh "$host" 'command -v python3 >/dev/null 2>&1' \
    || ylw "python3 is missing on $host — it cannot write to the socket at all."

  cat <<EOF

------------------------------------------------------------------------
Add to ~/.ssh/config on this Mac. RemoteForward does NOT expand ~, so both
paths are absolute:

  Host $host
      RemoteForward $remote_home/$SOCK_DIR_REL/sock $SOCK_DIR/sock
      StreamLocalBindUnlink yes

StreamLocalBindUnlink is what stops a socket left behind by a dropped
connection from blocking the next one. It is honoured by whichever end
creates the socket, so if forwarding still fails with "remote port
forwarding failed", the remote's /etc/ssh/sshd_config needs:

  StreamLocalBindUnlink yes

Then add this to $host:~/.claude/settings.json:

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

Make sure the listener is running on this Mac:

  ./install.sh --watch
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
  # Container dirs are optional: with none, this is an SSH-only listener.
  #
  # But this rewrites the plist wholesale, so passing none by accident used to
  # silently unregister every container — the spools kept filling and nothing
  # read them, with no error anywhere. Observed in practice, nine hours before
  # anyone noticed. Reuse whatever is already registered instead, and say so.
  if [ $# -eq 0 ] && [ -f "$AGENT_PLIST" ]; then
    registered=$(grep -o "<string>[^<]*/$SPOOL_NAME</string>" "$AGENT_PLIST" \
                 | sed -e 's|<string>||' -e 's|</string>||')
    while IFS= read -r spool; do
      [ -n "$spool" ] && set -- "$@" "$(dirname "$spool")"
    done <<REGISTERED
$registered
REGISTERED
    if [ $# -gt 0 ]; then
      ylw "Keeping the container directories already registered:"
      for dir in "$@"; do echo "  $dir"; done
      ylw "Run --uninstall first if you meant to drop them."
    fi
  fi

  mkdir -p "$HOOK_DIR" "$LOG_DIR" "$HOME/Library/LaunchAgents"
  cp "$SRC_DIR/notify-watch.py" "$HOOK_DIR/notify-watch.py"
  chmod +x "$HOOK_DIR/notify-watch.py"

  # The socket ssh forwards into. 0700 on the DIRECTORY is the control that
  # holds — a socket's own mode is not honoured on every OS, and this is a
  # channel into your Notification Center from another machine. mkdir -m sets
  # the mode at creation; the chmod also fixes a dir from an earlier install.
  mkdir -p -m 700 "$SOCK_DIR"
  chmod 700 "$SOCK_DIR"

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
        <string>1</string>
        <string>--listen</string>
        <string>$SOCK_DIR/sock</string>$spools
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
  grn "Watcher agent loaded."
  if [ $# -gt 0 ]; then
    echo "Draining container spools:"
    for dir in "$@"; do echo "  $dir/$SPOOL_NAME"; done
  fi
  echo "Listening for SSH sessions on $SOCK_DIR/sock"
  echo "Log: $LOG_DIR/watch.log"
  ylw "Set up each SSH host with: ./install.sh --remote <host>"
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
  # Gate on the exit status, not on grepping the output: spctl echoes the path
  # being assessed into the same stream, so an archive shipping its payload as
  # "alerter-accepted" puts the pass token inside its own rejection message.
  if ! spctl -a -t install "$bin" >/dev/null 2>&1; then
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
  term_app=$(detect_term_app)
  if [ -n "$term_app" ]; then
    sed -i '' "s/^TERM_APP=\"Ghostty\"/TERM_APP=\"$term_app\"/" "$HOOK_DIR/notify.conf"
    grn "Created config at $HOOK_DIR/notify.conf (clicks focus $term_app)"
    [ "$term_app" = "Ghostty" ] \
      || ylw "Tab-level focus is Ghostty-only; $term_app gets app-level activation."
  else
    grn "Created config at $HOOK_DIR/notify.conf"
    ylw "Could not identify your terminal — set TERM_APP in that file, or clicks"
    ylw "will try to focus Ghostty."
  fi
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
