#!/bin/sh
# Terminal app detection, shared by install.sh (baked into notify.conf as the
# static default) and alert.sh (re-run live at click time, since a single
# config value can't be right for every terminal app Claude Code happens to
# be running in on a given session).
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
