-- Rememoru login restore — TEMPLATE. Do not compile this file directly:
-- contrib/install-login-app.sh substitutes the __PLACEHOLDERS__ and builds
-- ~/Applications/RememoruRestore.app. Re-run the installer to change
-- settings; edits here are overwritten on the next install.

set cliPath to "__CLI_PATH__"
set snapshotPath to "__SNAPSHOT_PATH__"
set logPath to "/tmp/rememoru-restore.log"
set axPrefs to "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

-- Bail early if we can't drive the UI: macOS only shows the native AX
-- prompt once, so just open the pane and wait for the user to toggle us.
repeat 2 times
	set axStatus to do shell script (quoted form of cliPath) & " check-ax >/dev/null 2>&1; echo $?"
	if axStatus is "0" then exit repeat
	do shell script "open " & (quoted form of axPrefs)
	set choice to display dialog "Rememoru needs Accessibility permission." & return & return & "Enable \"" & (name of me) & "\" in the list that just opened, then click Retry." buttons {"Quit", "Retry"} default button 2 with icon caution
	if button returned of choice is "Quit" then return
end repeat

set axStatus to do shell script (quoted form of cliPath) & " check-ax >/dev/null 2>&1; echo $?"
if axStatus is not "0" then return

delay __DELAY_SECONDS__
try
	-- do shell script inherits the ~2-minute AppleEvent timeout; a real
	-- restore can run far longer, and a timeout may kill it mid-flight
	with timeout of 3600 seconds
		do shell script (quoted form of cliPath) & " restore " & (quoted form of snapshotPath) & " --launch --verbose >> " & (quoted form of logPath) & " 2>&1"
	end timeout
on error errMsg number errNum
	set tailText to ""
	try
		set tailText to do shell script "tail -6 " & (quoted form of logPath)
	end try
	set choice to display dialog "Rememoru restore failed (exit " & errNum & "):" & return & return & tailText & return & return & "Full log: " & logPath buttons {"Open Accessibility Settings", "OK"} default button 2 with icon caution
	if button returned of choice is "Open Accessibility Settings" then
		do shell script "open " & (quoted form of axPrefs)
	end if
end try
