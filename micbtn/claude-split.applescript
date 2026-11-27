-- claude-split.sh's half inside osascript: argv is MODEL, the gate FIFO, and the claude-warm path.
-- Ghostty 1.3 or later (its AppleScript dictionary: split, focus, surface configuration).
on run argv
	set {model, gate, warm} to argv
	set dir to ""
	try
		tell application "Ghostty" to set dir to working directory of focused terminal of selected tab of front window
	end try
	if dir is missing value or dir is "" then set dir to POSIX path of (path to home folder)
	-- Blocks until micbtn's verdict; a press that turned out to be a tap fails here and nothing happens.
	set cmd to do shell script "read v < " & quoted form of gate & " && [ \"$v\" = go ] && " & quoted form of warm & " take " & model & " " & quoted form of dir
	tell application "Ghostty"
		set cfg to new surface configuration
		set command of cfg to cmd
		set initial working directory of cfg to dir
		if (count of windows) is 0 then
			new window with configuration cfg
		else
			-- Up to four panes side by side; from then on the pane in focus is split top and bottom instead.
			set here to selected tab of front window
			set way to right
			if (count of terminals of here) is greater than or equal to 4 then set way to down
			set pane to split (focused terminal of here) direction way with configuration cfg
			-- A split halves the pane it splits, so the third pane would be a quarter and the first still a
			-- half: even them out, so the columns are the same width, and the panes within a column the same height.
			perform action "equalize_splits" on pane
			focus pane
		end if
		activate
	end tell
end run
