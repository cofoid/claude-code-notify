#!/bin/sh
# Terminal app detection, shared by install.sh (baked into notify.conf as the
# static default) and alert.sh (re-run live at click time, since a single
# config value can't be right for every terminal app Claude Code happens to
# be running in on a given session).
#
# TERM_PROGRAM covers most; the ones that don't set it are recognisable by TERM.
# Empty means "no idea", which the caller reports rather than guessing.
#
# CLAUDE_CODE_ENTRYPOINT=claude-vscode is checked LAST, not first: Claude Code's
# IDE auto-connect sets it whenever a running VS Code instance is found, even
# for a session in a real terminal with its own correct TERM_PROGRAM (e.g.
# ghostty) — so it must never outrank an actual terminal signal. Gating on
# TERM being empty too (not just TERM_PROGRAM) is what actually narrows this
# to the headless case the extension itself spawns (JSON stdio, no pty): any
# real pty sets TERM even when TERM_PROGRAM is unset, so an unrecognized real
# terminal still falls through correctly instead of being misread as VS Code.
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
  if [ -z "$app" ] && [ -z "${TERM:-}" ] && [ "${CLAUDE_CODE_ENTRYPOINT:-}" = "claude-vscode" ]; then
    app="Visual Studio Code"
  fi
  printf '%s' "$app"
}
