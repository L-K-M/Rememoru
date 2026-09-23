-- Rememoru login restore — TEMPLATE. Do not compile this file directly:
-- contrib/install-login-app.sh substitutes the __PLACEHOLDERS__ and builds
-- ~/Applications/RememoruRestore.app. Re-run the installer to change
-- settings; edits here are overwritten on the next install.

set cliPath to "__CLI_PATH__"
set snapshotPath to "__SNAPSHOT_PATH__"
set logPath to "/tmp/rememoru-restore.log"

delay __DELAY_SECONDS__
try
	do shell script (quoted form of cliPath) & " restore " & (quoted form of snapshotPath) & " --launch --verbose >> " & (quoted form of logPath) & " 2>&1"
on error errMsg number errNum
	set tailText to ""
	try
		set tailText to do shell script "tail -6 " & (quoted form of logPath)
	end try
	display dialog "Rememoru restore failed (exit " & errNum & "):" & return & return & tailText & return & return & "Full log: " & logPath buttons {"OK"} default button 1 with icon caution
end try
