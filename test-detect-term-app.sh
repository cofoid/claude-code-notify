#!/bin/sh
# Smallest thing that fails if detection breaks. Run: sh test-detect-term-app.sh
. "$(dirname "$0")/detect-term-app.sh"

fail=0
check() { # check <expected> <label> ; env comes from the caller's exports
  got="$(detect_term_app)"
  if [ "$got" = "$1" ]; then
    printf 'ok   %s -> %s\n' "$2" "$got"
  else
    printf 'FAIL %s -> expected "%s", got "%s"\n' "$2" "$1" "$got"
    fail=1
  fi
}

run() { # run <expected> <label> <VAR=VAL>...
  expected="$1"; label="$2"; shift 2
  unset TERM_PROGRAM TERM LC_TERMINAL CLAUDE_CODE_ENTRYPOINT
  for kv in "$@"; do
    eval "export ${kv%%=*}=\"\${kv#*=}\""
  done
  check "$expected" "$label"
}

run Ghostty  "ghostty bare"        TERM_PROGRAM=ghostty TERM=xterm-ghostty
run iTerm    "iTerm2 bare"         TERM_PROGRAM=iTerm.app TERM=xterm-256color
run iTerm    "iTerm2 under tmux"   TERM_PROGRAM=tmux TERM=tmux-256color LC_TERMINAL=iTerm2
run WezTerm  "WezTerm under tmux"  TERM_PROGRAM=tmux TERM=tmux-256color LC_TERMINAL=WezTerm
run kitty    "kitty by TERM"       TERM=xterm-kitty
run Ghostty  "ghostty + VS Code auto-connect wins on real terminal" \
    TERM_PROGRAM=ghostty TERM=xterm-ghostty CLAUDE_CODE_ENTRYPOINT=claude-vscode
run "Visual Studio Code" "headless vscode extension (no pty)" \
    CLAUDE_CODE_ENTRYPOINT=claude-vscode
run ""       "unknown terminal reports nothing" TERM=xterm-256color

exit "$fail"
