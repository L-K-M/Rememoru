#!/usr/bin/env bash
# End-to-end restore check on a real Mac. The process running it needs
# Accessibility (GitHub's macOS runners have it). It opens a TextEdit
# window, then asks Rememoru to
#   1. give the window a new frame, and
#   2. put it on a second desktop that does not exist yet,
# and checks both results against WindowServer.
#
# Usage: scripts/e2e-macos.sh [path/to/Rememoru binary]
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly APP="${1:-$SCRIPT_DIR/../dist/Rememoru.app/Contents/MacOS/Rememoru}"
readonly WORK="$(mktemp -d)"
readonly NOTE="$WORK/rememoru-e2e.txt"

fail() {
  echo "e2e: FAIL: $*" >&2
  exit 1
}

# snapshot_window FILE: print the saved TextEdit window of the note as JSON,
# or nothing
snapshot_window() {
  python3 - "$1" <<'PY'
import json, sys
snap = json.load(open(sys.argv[1]))
wins = [w for w in snap["windows"] if w["app"] == "TextEdit" and "rememoru-e2e" in (w.get("title") or "")]
if wins:
    print(json.dumps(wins[0]))
PY
}

printf 'Rememoru end-to-end check\n' > "$NOTE"
open -a TextEdit "$NOTE"

window=""
for _ in $(seq 1 40); do
  "$APP" snapshot -o "$WORK/before.json" > /dev/null
  window="$(snapshot_window "$WORK/before.json")"
  [[ -n "$window" ]] && break
  sleep 0.5
done
[[ -n "$window" ]] || fail "the TextEdit window never showed up in a snapshot"
echo "e2e: captured $window"

echo "e2e: 1. frame restore"
python3 - "$WORK/before.json" "$WORK/frame.json" <<'PY'
import json, sys
snap = json.load(open(sys.argv[1]))
display = snap["displays"][0]["frame"]
for w in snap["windows"]:
    if w["app"] == "TextEdit" and "rememoru-e2e" in (w.get("title") or ""):
        w["frame"] = {"x": display["x"] + 60, "y": display["y"] + 80, "w": 520, "h": 360}
json.dump(snap, open(sys.argv[2], "w"))
PY
"$APP" restore "$WORK/frame.json" || fail "restore reported failures (see above)"
"$APP" snapshot -o "$WORK/after-frame.json" > /dev/null
python3 - "$WORK/frame.json" "$WORK/after-frame.json" <<'PY' || fail "frame was not restored"
import json, sys
def window(path):
    snap = json.load(open(path))
    return next(w for w in snap["windows"] if w["app"] == "TextEdit" and "rememoru-e2e" in (w.get("title") or ""))
want, got = window(sys.argv[1])["frame"], window(sys.argv[2])["frame"]
print("e2e: wanted", want, "got", got)
assert abs(want["x"] - got["x"]) < 4 and abs(want["y"] - got["y"]) < 4, "position differs"
assert abs(want["w"] - got["w"]) < 24 and abs(want["h"] - got["h"]) < 24, "size differs"
PY

echo "e2e: 2. new desktop + move between Spaces"
python3 - "$WORK/after-frame.json" "$WORK/spaces.json" <<'PY'
import json, sys
snap = json.load(open(sys.argv[1]))
display = snap["displays"][0]
first = display["spaces"][0]
display["spaces"] = [first, "e2e-desktop-2"]
display["active_space"] = first
snap["spaces"] = [s for s in snap["spaces"] if s["uuid"] == first] + [{
    "uuid": "e2e-desktop-2", "id": 0, "type": "user",
    "display_uuid": display["uuid"], "index": 1, "active": False,
}]
for w in snap["windows"]:
    if w["app"] == "TextEdit" and "rememoru-e2e" in (w.get("title") or ""):
        w["space_uuid"] = "e2e-desktop-2"
json.dump(snap, open(sys.argv[2], "w"))
PY
"$APP" restore "$WORK/spaces.json" || fail "restore reported failures (see above)"
"$APP" snapshot -o "$WORK/after-spaces.json" > /dev/null
python3 - "$WORK/after-spaces.json" <<'PY' || fail "window is not on the second desktop"
import json, sys
snap = json.load(open(sys.argv[1]))
display = snap["displays"][0]
kinds = {s["uuid"]: s["type"] for s in snap["spaces"]}
desktops = [u for u in display["spaces"] if kinds.get(u) == "user"]
w = next(w for w in snap["windows"] if w["app"] == "TextEdit" and "rememoru-e2e" in (w.get("title") or ""))
print("e2e: desktops", desktops, "window on", w.get("space_uuid"))
assert len(desktops) >= 2, "no second desktop"
assert w.get("space_uuid") == desktops[1], "window not on desktop 2"
PY

echo "e2e: OK"
