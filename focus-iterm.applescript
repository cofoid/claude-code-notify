-- Focus the iTerm2 session belonging to a specific Claude Code session.
-- Usage: osascript focus-iterm.applescript "<session name>" "<cwd>"
--
-- Mirrors focus-ghostty.applescript: title first, working directory as an
-- unambiguous-only fallback. Claude Code writes the session name (from /rename)
-- into the terminal title, e.g. "✳ Tab-level focusing" — the leading glyph is a
-- live status spinner, so match by containment rather than equality.
--
-- Deliberately does NOT match on tty, even though iTerm exposes one. Under
-- `tmux -CC` (control mode) each tmux window is a native iTerm tab whose
-- session reports `tty = missing value`, because the pty belongs to tmux — so
-- tty would silently fail in exactly the setup this script exists to support.
-- The title escape sequence, by contrast, crosses tmux -CC and docker exec
-- unchanged, so `name` is the one identifier available in every mode.
--
-- Reads must be wrapped in `try` and scoped with `tell s to get ...`: iTerm has
-- no `working directory` property (the cwd lives in the session.path variable,
-- set by shell integration), a bare `variable named ... of s` raises -1723, and
-- a session can vanish mid-loop. Anything unreadable is skipped, not guessed at.

on run argv
	set sessionName to ""
	set targetCwd to ""
	if (count of argv) ≥ 1 then set sessionName to item 1 of argv
	if (count of argv) ≥ 2 then set targetCwd to item 2 of argv

	tell application "iTerm"
		-- Pass 1: title match. Skipped when the name is empty, since "contains
		-- empty string" is true for every session and would focus an arbitrary tab.
		if sessionName is not "" then
			repeat with w in windows
				repeat with t in tabs of w
					repeat with s in sessions of t
						set n to ""
						try
							set n to name of s
						end try
						if n is not "" and n contains sessionName then
							-- All three selects are load-bearing, outermost first.
							-- `select s` alone reaches the session inside its own tab but
							-- leaves whatever window was already frontmost in front:
							-- measured with a target in a background window, `current
							-- window` was unchanged afterwards. So the window has to be
							-- raised before selecting a tab inside it means anything.
							-- Inline rather than in a handler: loop references passed to
							-- one do not resolve, and the failure is invisible inside a try.
							select w
							select t
							select s
							activate
							return "focused:title"
						end if
					end repeat
				end repeat
			end repeat
		end if

		-- Pass 2: working-directory match, unique hits only — several tabs
		-- commonly sit in the same repo.
		--
		-- Records indices rather than the loop's own references. A saved window
		-- or tab reference resolves as "item 3 of every window" and raises
		-- -1719 once the loop that produced it has ended; absolute addressing
		-- survives. (A saved *session* reference does survive, which invites
		-- collecting only those — but selecting a session without first raising
		-- its window leaves the wrong window in front, per the note above.)
		if targetCwd is not "" then
			set hitCount to 0
			set hitW to 0
			set hitT to 0
			set hitS to 0
			set wi to 0
			repeat with w in windows
				set wi to wi + 1
				set ti to 0
				repeat with t in tabs of w
					set ti to ti + 1
					set si to 0
					repeat with s in sessions of t
						set si to si + 1
						set p to ""
						try
							tell s to set p to (get variable named "session.path")
						end try
						if p is targetCwd then
							set hitCount to hitCount + 1
							set {hitW, hitT, hitS} to {wi, ti, si}
						end if
					end repeat
				end repeat
			end repeat
			if hitCount is 1 then
				select window hitW
				select tab hitT of window hitW
				select session hitS of tab hitT of window hitW
				activate
				return "focused:cwd"
			end if
		end if
	end tell

	return "no-unique-match"
end run
