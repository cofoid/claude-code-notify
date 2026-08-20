#!/bin/sh
# Smallest thing that fails if detection breaks. Run: sh test-detect-term-app.sh
. "$(dirname "$0")/detect-term-app.sh"

fail=0

# run <expected> <label> <VAR=VAL>...
# Clears every variable detect_term_app reads before each case, so a case only
# sees the environment it declares.
run() {
	expected="$1"
	label="$2"
	shift 2
	unset TERM_PROGRAM TERM LC_TERMINAL CLAUDE_CODE_ENTRYPOINT
	for kv in "$@"; do export "$kv"; done
	got="$(detect_term_app)"
	if [ "$got" = "$expected" ]; then
		printf 'ok   %s -> %s\n' "$label" "$got"
	else
		printf 'FAIL %s -> expected "%s", got "%s"\n' "$label" "$expected" "$got"
		fail=1
	fi
}

run Ghostty "ghostty bare" TERM_PROGRAM=ghostty TERM=xterm-ghostty
run iTerm "iTerm2 bare" TERM_PROGRAM=iTerm.app TERM=xterm-256color
run iTerm "iTerm2 under tmux" TERM_PROGRAM=tmux TERM=tmux-256color LC_TERMINAL=iTerm2
run kitty "kitty by TERM" TERM=xterm-kitty
run Ghostty "VS Code auto-connect loses to a real terminal" \
	TERM_PROGRAM=ghostty TERM=xterm-ghostty CLAUDE_CODE_ENTRYPOINT=claude-vscode
run "Visual Studio Code" "headless vscode extension (no pty)" \
	CLAUDE_CODE_ENTRYPOINT=claude-vscode
run "" "unknown terminal reports nothing" TERM=xterm-256color

exit "$fail"
