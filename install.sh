#!/bin/sh
# claude-code-notify installer.
#
#   ./install.sh            install / update
#   ./install.sh --uninstall  remove hook files (leaves settings.json alone)
#
# Idempotent: safe to re-run. Never edits settings.json for you — it prints the
# snippet to paste, because settings.json commonly holds hand-tuned permissions
# and hooks that an automated edit could clobber.

set -e

HOOK_DIR="$HOME/.claude/hooks"
BIN_DIR="$HOME/.local/bin"
SRC_DIR=$(cd "$(dirname "$0")" && pwd)
ALERTER_REPO="vjeantet/alerter"

red()  { printf '\033[31m%s\033[0m\n' "$1"; }
grn()  { printf '\033[32m%s\033[0m\n' "$1"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$1"; }

if [ "$1" = "--uninstall" ]; then
  rm -f "$HOOK_DIR/notify.sh" "$HOOK_DIR/focus-ghostty.applescript"
  grn "Removed hook files from $HOOK_DIR"
  ylw "Remove the Stop and Notification entries from ~/.claude/settings.json by hand."
  ylw "The alerter binary at $BIN_DIR/alerter was left in place."
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
cp "$SRC_DIR/focus-ghostty.applescript" "$HOOK_DIR/focus-ghostty.applescript"
chmod +x "$HOOK_DIR/notify.sh"
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
