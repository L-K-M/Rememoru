#!/usr/bin/env bash
# End-to-end restore check on a real Mac. The process running it needs
# Accessibility (GitHub's macOS runners have it). It opens TextEdit
# windows, then asks Rememoru to
#   1. give a window a new frame,
#   2. put it on a second desktop that does not exist yet,
#   3. make it a fullscreen space right after desktop 1, and
#   4. pair it with a second window in Split View,
# and checks each result against WindowServer.
#
# Usage: scripts/e2e-macos.sh [path/to/Rememoru binary]
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly APP="${1:-$SCRIPT_DIR/../dist/Rememoru.app/Contents/MacOS/Rememoru}"
readonly WORK="$(mktemp -d)"
readonly NOTE="$WORK/rememoru-e2e.txt"
readonly NOTE2="$WORK/rememoru-e2e-pair.txt"

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

echo "e2e: 3. fullscreen space after desktop 1"
python3 - "$WORK/after-spaces.json" "$WORK/fullscreen.json" <<'PY'
import json, sys
snap = json.load(open(sys.argv[1]))
display = snap["displays"][0]
first = display["spaces"][0]
display["spaces"] = [first, "e2e-fullscreen"]
display["active_space"] = first
snap["spaces"] = [s for s in snap["spaces"] if s["uuid"] == first] + [{
    "uuid": "e2e-fullscreen", "id": 0, "type": "fullscreen",
    "display_uuid": display["uuid"], "index": 1, "active": False,
}]
for w in snap["windows"]:
    if w["app"] == "TextEdit" and "rememoru-e2e" in (w.get("title") or ""):
        w["space_uuid"] = "e2e-fullscreen"
        w["frame"] = dict(display["frame"])
json.dump(snap, open(sys.argv[2], "w"))
PY
"$APP" restore "$WORK/fullscreen.json" || fail "restore reported failures (see above)"
"$APP" snapshot -o "$WORK/after-fullscreen.json" > /dev/null
python3 - "$WORK/after-fullscreen.json" <<'PY' || fail "window is not fullscreen right after desktop 1"
import json, sys
snap = json.load(open(sys.argv[1]))
display = snap["displays"][0]
kinds = {s["uuid"]: s["type"] for s in snap["spaces"]}
w = next(w for w in snap["windows"] if w["app"] == "TextEdit" and "rememoru-e2e" in (w.get("title") or ""))
order = [kinds.get(u) for u in display["spaces"]]
print("e2e: space order", order, "window on", kinds.get(w.get("space_uuid")))
assert kinds.get(w.get("space_uuid")) == "fullscreen", "window not on a fullscreen space"
assert display["spaces"].index(w["space_uuid"]) == 1, "fullscreen space is not second"
PY

echo "e2e: 4. Split View pair"
printf 'Rememoru end-to-end check, second window\n' > "$NOTE2"
open -a TextEdit "$NOTE2"
for _ in $(seq 1 40); do
  "$APP" snapshot -o "$WORK/with-pair.json" > /dev/null
  python3 - "$WORK/with-pair.json" <<'PY' && break
import json, sys
snap = json.load(open(sys.argv[1]))
titles = [w.get("title") or "" for w in snap["windows"] if w["app"] == "TextEdit"]
sys.exit(0 if any("rememoru-e2e-pair" in t for t in titles) else 1)
PY
  sleep 0.5
done
python3 - "$WORK/with-pair.json" "$WORK/split.json" <<'PY'
import json, sys
snap = json.load(open(sys.argv[1]))
display = snap["displays"][0]
kinds = {s["uuid"]: s["type"] for s in snap["spaces"]}
first = next(u for u in display["spaces"] if kinds.get(u) == "user")
display["spaces"] = [first, "e2e-split"]
display["active_space"] = first
snap["spaces"] = [s for s in snap["spaces"] if s["uuid"] == first] + [{
    "uuid": "e2e-split", "id": 0, "type": "tiled",
    "display_uuid": display["uuid"], "index": 1, "active": False,
}]
f = display["frame"]
for w in snap["windows"]:
    title = w.get("title") or ""
    if w["app"] != "TextEdit" or "rememoru-e2e" not in title:
        continue
    right = "rememoru-e2e-pair" in title
    w["space_uuid"] = "e2e-split"
    w["side"] = "right" if right else "left"
    w["frame"] = {"x": f["x"] + (f["w"] / 2 if right else 0), "y": f["y"], "w": f["w"] / 2, "h": f["h"]}
json.dump(snap, open(sys.argv[2], "w"))
PY
"$APP" restore "$WORK/split.json" || fail "restore reported failures (see above)"
"$APP" snapshot -o "$WORK/after-split.json" > /dev/null
python3 - "$WORK/after-split.json" <<'PY' || fail "the two windows are not a Split View pair"
import json, sys
snap = json.load(open(sys.argv[1]))
kinds = {s["uuid"]: s["type"] for s in snap["spaces"]}
pair = {("right" if "rememoru-e2e-pair" in (w.get("title") or "") else "left"): w
        for w in snap["windows"] if w["app"] == "TextEdit" and "rememoru-e2e" in (w.get("title") or "")}
spaces = {side: w.get("space_uuid") for side, w in pair.items()}
print("e2e: pair spaces", spaces, "kinds", {side: kinds.get(u) for side, u in spaces.items()},
      "sides", {side: w.get("side") for side, w in pair.items()})
assert len(pair) == 2 and spaces["left"] == spaces["right"], "windows are on different spaces"
assert kinds.get(spaces["left"]) == "tiled", "their space is not Split View"
assert pair["left"].get("side") == "left" and pair["right"].get("side") == "right", "sides are swapped"
PY

echo "e2e: OK"
