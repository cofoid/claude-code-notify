-- Focus the Ghostty terminal surface belonging to a specific Claude Code session.
-- Usage: osascript focus-ghostty.applescript "<session name>" "<cwd>"
--
-- Claude Code writes the session name (from /rename) into the terminal title,
-- e.g. "⠂ Claude Audible Alerts" — the leading glyph is a live status spinner,
-- so match by containment rather than equality. Falls back to working directory,
-- but only when that match is unambiguous: several tabs commonly share a repo.

on run argv
	set sessionName to ""
	set targetCwd to ""
	if (count of argv) ≥ 1 then set sessionName to item 1 of argv
	if (count of argv) ≥ 2 then set targetCwd to item 2 of argv

	tell application "Ghostty"
		-- Pass 1: title match. Skipped when the name is empty, since "contains
		-- empty string" is true for every surface and would focus an arbitrary tab.
		if sessionName is not "" then
			repeat with w in windows
				repeat with t in tabs of w
					repeat with s in terminals of t
						if (name of s) contains sessionName then
							focus s
							return "focused:title"
						end if
					end repeat
				end repeat
			end repeat
		end if

		-- Pass 2: working-directory match, unique hits only.
		if targetCwd is not "" then
			set hits to {}
			repeat with w in windows
				repeat with t in tabs of w
					repeat with s in terminals of t
						if (working directory of s) is targetCwd then set end of hits to s
					end repeat
				end repeat
			end repeat
			if (count of hits) is 1 then
				focus (item 1 of hits)
				return "focused:cwd"
			end if
		end if
	end tell

	return "no-unique-match"
end run
