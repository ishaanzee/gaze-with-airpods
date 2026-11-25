-- claude-split.sh's half inside osascript: argv is MODEL, the gate FIFO, and the claude-warm path.
on run argv
	set {model, gate, warm} to argv
	set dir to ""
	try
		tell application "iTerm2"
			tell current session of current tab of current window to set dir to (get variable named "session.path") as text
		end tell
	end try
	if dir is missing value or dir is "" then set dir to POSIX path of (path to home folder)
	-- Blocks until micbtn's verdict; a press that turned out to be a tap fails here and nothing happens.
	set cmd to do shell script "read v < " & quoted form of gate & " && [ \"$v\" = go ] && " & quoted form of warm & " take " & model & " " & quoted form of dir
	tell application "iTerm2"
		if (count of windows) is 0 then
			create window with default profile command cmd
		else
			tell current session of current tab of current window
				set pane to (split vertically with same profile command cmd)
			end tell
			tell pane to select
		end if
		activate
	end tell
end run
