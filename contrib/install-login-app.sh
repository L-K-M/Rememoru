#!/bin/sh
# Interactive installer for the Rememoru login-restore app.
# Builds ~/Applications/RememoruRestore.app from the AppleScript template,
# with the CLI path, snapshot file and startup delay baked in.
#
# Non-interactive: set REMEMORU_CLI / REMEMORU_SNAPSHOT / REMEMORU_DELAY
# (or pipe answers on stdin). REMEMORU_NONINTERACTIVE=1 skips all prompts.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"
tpl="$here/rememoru-login.applescript"
app="$HOME/Applications/RememoruRestore.app"
log="/tmp/rememoru-restore.log"

noninteractive() { [ -n "${REMEMORU_NONINTERACTIVE:-}" ] || [ ! -t 0 ]; }

# prompt <question> <default> -> echoes chosen value
prompt() {
    if noninteractive; then
        printf '%s\n' "$2"
        return
    fi
    printf '%s [%s]: ' "$1" "$2" >&2
    read -r ans || ans=""
    printf '%s\n' "${ans:-$2}"
}

# prompt_yn <question> <default y|n> -> 0 for yes
prompt_yn() {
    if noninteractive; then
        [ "$2" = y ]; return
    fi
    printf '%s [%s]: ' "$1" "$( [ "$2" = y ] && echo Y/n || echo y/N )" >&2
    read -r ans || ans=""
    case "${ans:-$2}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

def_cli="$repo/rememoru-cli"
# newest snapshot in repo dir or ~/rememoru-snapshot.json as default
def_snap="$(ls -t "$repo"/rememoru-*.json 2>/dev/null | head -1)"
[ -n "$def_snap" ] || def_snap="$HOME/rememoru-snapshot.json"

echo "Rememoru login-restore setup" >&2
echo >&2

cli="${REMEMORU_CLI:-$(prompt "Path to rememoru-cli" "$def_cli")}"
if [ ! -x "$cli" ]; then
    echo "warning: $cli is not executable" >&2
fi

snap="${REMEMORU_SNAPSHOT:-$(prompt "Snapshot file to restore" "$def_snap")}"
if [ ! -f "$snap" ] && prompt_yn "No such snapshot — capture one now?" y; then
    "$cli" snapshot -o "$snap" || echo "snapshot failed — continuing anyway" >&2
fi

delay="${REMEMORU_DELAY:-$(prompt "Seconds to wait after login" "60")}"

# escape \ first, then & | " — covers both the sed substitution and the
# AppleScript string literal the values land in
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/[&|"]/\\&/g'; }
tmp="$(mktemp -t rememoru-login.XXXXXX)"
trap 'rm -f "$tmp"' EXIT
sed -e "s|__CLI_PATH__|$(esc "$cli")|" \
    -e "s|__SNAPSHOT_PATH__|$(esc "$snap")|" \
    -e "s|__DELAY_SECONDS__|$(esc "$delay")|" \
    "$tpl" > "$tmp"

mkdir -p "$HOME/Applications"
osacompile -o "$app" "$tmp"
echo >&2
echo "Built: $app" >&2

if prompt_yn "Add to Login Items now (System Events prompt)?" y; then
    if osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$app\", hidden:false}" >/dev/null 2>&1; then
        echo "Added to Login Items." >&2
    else
        echo "Couldn't add it automatically — add \"$app\" in" >&2
        echo "System Settings → General → Login Items." >&2
    fi
else
    echo "Add it manually: System Settings → General → Login Items → $app" >&2
fi

cat >&2 <<EOF

Done. Reminders:
  - Run the app once now (open "$app") and approve Accessibility +
    Screen Recording when prompted — the grant belongs to the app itself.
  - First fire happens after a ${delay}s delay at next login;
    log: $log
  - Re-run this installer any time to change paths or the delay.
EOF
