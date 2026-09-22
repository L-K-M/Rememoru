-- Rememoru login restore — compile with:
--   osacompile -o ~/Applications/RememoruRestore.app contrib/rememoru-login.applescript
-- then add the app to System Settings → General → Login Items.
-- Edit the two paths below to match your checkout and snapshot file.

set waitSeconds to 60
set cliPath to (POSIX path of (path to home folder)) & "Rememoru/rememoru-cli"
set snapshotPath to (POSIX path of (path to home folder)) & "rememoru-snapshot.json"
set logPath to "/tmp/rememoru-restore.log"

delay waitSeconds
do shell script (quoted form of cliPath) & " restore " & (quoted form of snapshotPath) & " --launch --verbose >> " & logPath & " 2>&1"
