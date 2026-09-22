#!/bin/sh
# Build ~/Applications/RememoruRestore.app from contrib/rememoru-login.applescript
# and print the remaining manual steps (Login Item + Accessibility grant).
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
app="$HOME/Applications/RememoruRestore.app"

mkdir -p "$HOME/Applications"
osacompile -o "$app" "$here/rememoru-login.applescript"

cat <<EOF
Built: $app

Remaining steps (once):
  1. Edit the script first if your checkout/snapshot paths differ
     (re-run this script after editing to rebuild).
  2. System Settings → General → Login Items → add "RememoruRestore".
  3. Run it once manually (double-click or 'open "$app"'), then grant it
     Accessibility + Screen Recording when prompted.

Logs go to /tmp/rememoru-restore.log.
EOF
