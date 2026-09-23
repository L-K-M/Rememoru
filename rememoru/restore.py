"""Restore orchestration.

Phases:
  1. ensure enough user (desktop) spaces per display      — Mission Control '+'
  2. match snapshot windows to live windows
  3. move windows onto their target user spaces           — bridged WS op / MC drag / relaunch
  4. restore frames (position/size)                        — AX
  5. recreate fullscreen spaces in saved order             — AXFullScreen
  6. recreate split-view pairs in saved order              — green-button UI automation
  7. reorder spaces to match the snapshot                  — MC thumbnail drags
  8. restore the active space per display                  — SLS + hide-old / MC click
"""
import json
import subprocess
import time

from . import ax, cg, mc, model, skylight


def _norm(s):
    return (s or "").strip().lower()


def _title_score(saved, live):
    s, l = _norm(saved), _norm(live)
    if s == l:
        return 100 if s else 50
    if not s or not l:
        return 20
    if l.startswith(s) or s.startswith(l):
        return 60
    if s in l or l in s:
        return 40
    return 0


class Restorer(object):
    def __init__(self, snap, opts, log=print):
        self.snap = snap
        self.o = opts
        self.log = log
        for i, w in enumerate(self.snap["windows"]):
            w["_i"] = i
        self.sls = skylight.Connection()
        self.displays = model.display_list(self.sls, log=log)
        self.display_by_uuid = {d["uuid"]: d for d in self.displays}
        self.failed = []      # human-readable failure lines
        self.missing = []     # snapshot windows with no live match
        self.refresh()

    # ------------------------------------------------------------------ util
    def refresh(self):
        self.live_spaces = self.sls.spaces()
        self.space_by_id = {s["id"]: s for s in self.live_spaces}
        self.live_windows = model.current_windows(self.sls)
        self.space_of_wid = {w["id"]: w.get("space_id") for w in self.live_windows}

    def vlog(self, msg):
        if self.o.verbose:
            self.log(msg)

    def _disp_frame(self, display_uuid):
        d = self.display_by_uuid.get(display_uuid)
        return d["frame"] if d else None

    def _disp_map(self):
        """snapshot display uuid -> current display dict (or None)."""
        m = {}
        cur = self.displays
        for i, sd in enumerate(self.snap["displays"]):
            d = self.display_by_uuid.get(sd["uuid"])
            if d is None and self.o.remap_displays:
                d = cur[i] if i < len(cur) else next(
                    (x for x in cur if x["main"]), cur[0] if cur else None
                )
            m[sd["uuid"]] = d
        return m

    def _user_spaces(self, display_uuid):
        return [
            s for s in self.live_spaces
            if s["display_uuid"] == display_uuid and s["type"] == 0
        ]

    def _snap_user_ordinal(self):
        """snapshot space uuid -> ordinal among its display's user spaces."""
        ordinals = {}
        for sd in self.snap["displays"]:
            n = 0
            for suuid in sd["spaces"]:
                sp = self._snap_space(suuid)
                if sp and sp["type"] == "user":
                    ordinals[suuid] = n
                    n += 1
        return ordinals

    def _snap_space(self, uuid):
        if uuid is None:
            return None
        return next(
            (s for s in self.snap["spaces"]
             if s["uuid"] is not None and s["uuid"] == uuid),
            None,
        )

    def _snap_space_windows(self, space_uuid):
        return [w for w in self.snap["windows"] if w.get("space_uuid") == space_uuid]

    # ------------------------------------------------------------- matching
    def match_windows(self):
        """Greedy app+title matching: snap window -> live window dict."""
        pairs = []
        for i, sw in enumerate(self.snap["windows"]):
            for j, lw in enumerate(self.live_windows):
                same_app = (
                    sw.get("bundle_id")
                    and sw["bundle_id"] == lw.get("bundle_id")
                ) or _norm(sw["app"]) == _norm(lw["app"])
                if not same_app:
                    continue
                sc = _title_score(sw.get("title"), lw.get("title"))
                if sc > 0:
                    pairs.append((sc, i, j))
        pairs.sort(reverse=True)
        # snap index -> live window dict. The dicts stay valid across
        # refresh() because we only rely on their id/pid/title fields.
        matched = {}
        used = set()
        for sc, i, j in pairs:
            if i in matched or j in used:
                continue
            matched[i] = self.live_windows[j]
            used.add(j)
        self.wmatch = matched
        self.missing = [
            w for i, w in enumerate(self.snap["windows"]) if i not in matched
        ]
        return matched

    def live_for(self, snap_window):
        return self.wmatch.get(snap_window["_i"])

    def _ax_window(self, live_win):
        return ax.find_window(
            live_win["pid"], live_win.get("title"), live_win.get("frame")
        )

    # ----------------------------------------------------------- phase impls
    def phase_spaces(self, disp_map):
        """Create missing user spaces per display via Mission Control.

        MC is opened once — calling `open -a "Mission Control"` while it is
        already open can toggle it closed again."""
        deficits = []  # (current_display_dict, count)
        for sd in self.snap["displays"]:
            cur = disp_map[sd["uuid"]]
            if cur is None:
                self.log("  ! display %s not connected — skipping its spaces"
                         % (sd["uuid"] or "?")[:8])
                continue
            need = sum(
                1 for u in sd["spaces"]
                if (self._snap_space(u) or {}).get("type") == "user"
            )
            have = len(self._user_spaces(cur["uuid"]))
            if have < need:
                deficits.append((cur, need - have))
                self.log("  %sdisplay %s: needs %d desktops, has %d"
                         % ("would create on " if self.o.dry_run else "",
                            (cur["uuid"] or "?")[:8], need, have))
        if not deficits or self.o.dry_run:
            return
        if not mc.open_mc():
            self.failed.append("could not open Mission Control")
            return
        for cur, n in deficits:
            mc.create_spaces(cur["frame"], n, self.log)
        mc.close_mc()
        time.sleep(0.5)
        self.refresh()

    def _target_sid_for_user_space(self, snap_space_uuid, display_uuid):
        """Map a snapshot user space to the live space id by ordinal."""
        ordinals = self._snap_user_ordinal()
        k = ordinals.get(snap_space_uuid)
        if k is None:
            return None
        live = self._user_spaces(display_uuid)
        return live[k]["id"] if k < len(live) else None

    def _move_window(self, live_win, target_sid):
        wid = live_win["id"]
        if self.space_of_wid.get(wid) == target_sid:
            return True
        ok = self.sls.move_windows_to_space([wid], target_sid)
        if ok:
            deadline = time.time() + 2.0
            while time.time() < deadline:
                time.sleep(0.15)
                self.refresh()
                if self.space_of_wid.get(wid) == target_sid:
                    return True
        return False

    def _drag_move_fallback(self, live_win, target_sid, disp_frame):
        """Mission Control drag fallback for one window."""
        self.vlog("  trying Mission Control drag for %r" % live_win["title"])
        src_sid = self.space_of_wid.get(live_win["id"])
        src_space = self.space_by_id.get(src_sid)
        if not src_space:
            return False
        # the source space must be the display's active one for MC to show it
        disp_uuid = src_space["display_uuid"]
        if not self._focus_sid(disp_uuid, src_sid):
            return False
        if not mc.open_mc():
            return False
        buttons = mc.space_buttons(disp_frame)
        order = [s["id"] for s in self.live_spaces
                 if s["display_uuid"] == disp_uuid]
        try:
            idx = order.index(target_sid)
        except ValueError:
            mc.close_mc()
            return False
        ok = False
        if idx < len(buttons):
            ok = mc.drag_window_to_space(
                disp_frame, live_win.get("title") or "", buttons[idx], self.log
            )
        mc.close_mc()
        time.sleep(0.3)
        self.refresh()
        return ok and self.space_of_wid.get(live_win["id"]) == target_sid

    def _relaunch_fallback(self, live_win, target_sid, disp_uuid):
        """ShiftPlus-style: switch to the target space, relaunch the app so
        its new window lands there. Opt-in — can lose unsaved state."""
        app = live_win["app"]
        self.log("  relaunching %s onto target space" % app)
        self._focus_sid(disp_uuid, target_sid)
        try:
            subprocess.run(
                ["osascript", "-e", 'tell application "%s" to quit' % app],
                capture_output=True, timeout=10,
            )
            time.sleep(1.5)
            subprocess.run(["open", "-a", app], capture_output=True, timeout=10)
        except (subprocess.TimeoutExpired, OSError) as e:
            self.log("  ! relaunch failed: %s" % e)
        time.sleep(2.0)
        self.refresh()

    def phase_assign_spaces(self, disp_map):
        self.log("phase: assigning windows to spaces")
        for sw in self.snap["windows"]:
            lw = self.live_for(sw)
            if lw is None:
                continue
            sp = self._snap_space(sw.get("space_uuid"))
            if not sp or sp["type"] != "user":
                continue  # fullscreen/tiled handled later
            disp = disp_map.get(sw.get("display_uuid"))
            if disp is None:
                continue
            sid = self._target_sid_for_user_space(sw["space_uuid"], disp["uuid"])
            if sid is None:
                continue
            if self.o.dry_run:
                if self.space_of_wid.get(lw["id"]) != sid:
                    self.log("  would move %r (%s) to space #%d"
                             % (sw.get("title"), sw["app"], sid))
                continue
            # space moves only work within a display — if the window is on
            # the wrong display, park it on the target one first
            lf, df = lw.get("frame") or {}, disp["frame"]
            cx = lf.get("x", 0) + lf.get("w", 0) / 2.0
            cy = lf.get("y", 0) + lf.get("h", 0) / 2.0
            if not (df["x"] <= cx <= df["x"] + df["w"]
                    and df["y"] <= cy <= df["y"] + df["h"]):
                el = self._ax_window(lw)
                if el is not None:
                    ax.set_frame(el, df["x"] + df["w"] / 2 - 400,
                                 df["y"] + df["h"] / 2 - 300, 800, 600)
                    time.sleep(0.3)
            if self._move_window(lw, sid):
                continue
            # fallbacks
            moved = False
            if "mc" in self.o.move_fallback:
                moved = self._drag_move_fallback(lw, sid, disp["frame"])
            if not moved and "relaunch" in self.o.move_fallback:
                self._relaunch_fallback(lw, sid, disp["uuid"])
                moved = self.space_of_wid.get(lw["id"]) == sid
            if not moved:
                self.failed.append(
                    "could not move %r (%s) to its space"
                    % (sw.get("title"), sw["app"])
                )

    def phase_frames(self, disp_map):
        self.log("phase: restoring frames")
        for sw in self.snap["windows"]:
            if sw.get("space_type") in ("fullscreen", "tiled"):
                continue
            lw = self.live_for(sw)
            if lw is None:
                continue
            if self.o.dry_run:
                self.vlog("  would frame %r -> %s" % (sw.get("title"), sw["frame"]))
                continue
            el = self._ax_window(lw)
            if el is None:
                self.failed.append("no AX window for %r (%s)"
                                   % (sw.get("title"), sw["app"]))
                continue
            f = sw["frame"]
            ax.set_frame(el, f["x"], f["y"], f["w"], f["h"])

    def _live_space_of(self, live_win):
        return self.space_by_id.get(self.space_of_wid.get(live_win["id"]))

    def _enter_fullscreen(self, live_win, disp):
        el = self._ax_window(live_win)
        if el is None:
            return False
        f = disp["frame"]
        # park the window centered on the target display, then fullscreen it
        ax.set_frame(
            el, f["x"] + f["w"] / 2 - 600, f["y"] + f["h"] / 2 - 400, 1200, 800
        )
        time.sleep(0.2)
        if not ax.set_fullscreen(el, True):
            mi = ax.find_menu_item(
                live_win["pid"], ["Window"],
                lambda t: "full screen" in t.lower() or "fullscreen" in t.lower(),
            )
            if mi is None or not ax.press(mi):
                return False
        wid = live_win["id"]
        deadline = time.time() + 4
        while time.time() < deadline:
            self.refresh()
            sp = self._live_space_of(live_win)
            if sp and sp["type"] == 4:
                return True
            time.sleep(0.25)
        return False

    def phase_fullscreen(self, disp_map):
        todo = [
            s for s in self.snap["spaces"] if s["type"] == "fullscreen"
        ]
        if not todo:
            return
        self.log("phase: recreating %d fullscreen space(s)" % len(todo))
        for sp in sorted(todo, key=lambda s: (
            self._snap_display_order(s["display_uuid"]), s["index"])):
            disp = disp_map.get(sp["display_uuid"])
            wins = self._snap_space_windows(sp["uuid"])
            lw = self.live_for(wins[0]) if wins else None
            if disp is None or lw is None:
                self.failed.append(
                    "fullscreen space %s: window unavailable (%s)"
                    % ((sp["uuid"] or "?")[:8],
                       (wins[0].get("app") if wins else "no windows saved"))
                )
                continue
            cur = self._live_space_of(lw)
            if cur and cur["type"] == 4:
                continue  # already fullscreen somewhere; order fixed later
            if self.o.dry_run:
                self.log("  would fullscreen %r (%s)"
                         % (lw.get("title"), lw["app"]))
                continue
            if not self._enter_fullscreen(lw, disp):
                self.failed.append("could not fullscreen %r (%s)"
                                   % (lw.get("title"), lw["app"]))
            time.sleep(0.4)

    def _snap_display_order(self, duuid):
        for i, sd in enumerate(self.snap["displays"]):
            if sd["uuid"] == duuid:
                return i
        return 99

    def phase_tiled(self, disp_map):
        todo = [s for s in self.snap["spaces"] if s["type"] == "tiled"]
        if not todo or not self.o.split:
            if todo:
                self.log("phase: skipping %d split-view space(s) (--no-split)"
                         % len(todo))
            return
        self.log("phase: recreating %d split-view space(s)" % len(todo))
        for sp in sorted(todo, key=lambda s: (
            self._snap_display_order(s["display_uuid"]), s["index"])):
            disp = disp_map.get(sp["display_uuid"])
            wins = self._snap_space_windows(sp["uuid"])
            left = next((w for w in wins if w.get("side") == "left"),
                        wins[0] if wins else None)
            right = next((w for w in wins if w.get("side") == "right"), None)
            lw_l = self.live_for(left) if left else None
            lw_r = self.live_for(right) if right else None
            if disp is None or lw_l is None or lw_r is None:
                self.failed.append(
                    "split-view pair unavailable: %r / %r"
                    % ((left or {}).get("title"), (right or {}).get("title"))
                )
                continue
            # already tiled together?
            cur = self._live_space_of(lw_l)
            if cur and cur["type"] == 5 and self.space_of_wid.get(
                lw_r["id"]) == cur["id"]:
                continue
            if self.o.dry_run:
                self.log("  would split-view %r | %r"
                         % (lw_l.get("title"), lw_r.get("title")))
                continue
            self._make_split(lw_l, lw_r, disp)

    def _make_split(self, lw_left, lw_right, disp):
        # precondition: both windows windowed, on the target display, ideally
        # on the same user space so the picker can offer the companion
        for lw in (lw_left, lw_right):
            el = self._ax_window(lw)
            if el is None:
                self.failed.append("no AX window for %r" % lw.get("title"))
                return
            if ax.is_fullscreen(el):
                ax.set_fullscreen(el, False)
                time.sleep(0.8)
        sp_l = self._live_space_of(lw_left)
        sp_r = self._live_space_of(lw_right)
        if sp_l and sp_r and sp_l["id"] != sp_r["id"]:
            self._move_window(lw_right, sp_l["id"])
        f = disp["frame"]
        el_l = self._ax_window(lw_left)
        ax.set_frame(el_l, f["x"] + 200, f["y"] + 150, 900, 700)
        time.sleep(0.3)
        ok = mc.split_view(
            el_l, lw_left["pid"], lw_left.get("title") or "",
            "left", lw_right["pid"], lw_right.get("title") or "",
            f, self.log,
        )
        if not ok:
            self.failed.append(
                "split-view automation failed for %r + %r (see above)"
                % (lw_left.get("title"), lw_right.get("title"))
            )
            return
        deadline = time.time() + 6
        while time.time() < deadline:
            self.refresh()
            cur = self._live_space_of(lw_left)
            if cur and cur["type"] == 5:
                return
            time.sleep(0.3)
        self.failed.append(
            "split-view space never materialized for %r + %r"
            % (lw_left.get("title"), lw_right.get("title"))
        )

    # --------------------------------------------------------------- order
    def phase_order(self, disp_map):
        if not self.o.reorder:
            return
        self.refresh()
        for sd in self.snap["displays"]:
            cur = disp_map[sd["uuid"]]
            if cur is None:
                continue
            desired = self._desired_order(sd, cur["uuid"])
            if not desired:
                continue
            current = [
                s["id"] for s in self.live_spaces
                if s["display_uuid"] == cur["uuid"]
            ]
            if current[: len(desired)] == desired:
                continue
            self.log("  reordering spaces on display %s"
                     % (cur["uuid"] or "?")[:8])
            if self.o.dry_run:
                self.log("    current: %s\n    desired: %s"
                         % (current, desired))
                continue
            self.log("    current: %s\n    desired: %s" % (current, desired))
            if not mc.open_mc():
                self.failed.append("could not open MC for reorder")
                return
            cur_uuid = cur["uuid"]
            mc.reorder_spaces(
                cur["frame"], desired,
                lambda: [
                    s["id"] for s in self.sls.spaces()
                    if s["display_uuid"] == cur_uuid
                ],
                self.log,
            )
            mc.close_mc()
            self.refresh()

    def _desired_order(self, snap_display, display_uuid):
        """Live space ids in the snapshot's order, for one display."""
        out = []
        ordinals = self._snap_user_ordinal()
        for suuid in snap_display["spaces"]:
            sp = self._snap_space(suuid)
            if not sp:
                continue
            if sp["type"] == "user":
                k = ordinals.get(suuid)
                live = self._user_spaces(display_uuid)
                if k is not None and k < len(live):
                    out.append(live[k]["id"])
            elif sp["type"] in ("fullscreen", "tiled"):
                wins = self._snap_space_windows(suuid)
                lw = self.live_for(wins[0]) if wins else None
                cur = self._live_space_of(lw) if lw else None
                if cur and cur["type"] == sp_type_id(sp["type"]):
                    out.append(cur["id"])
        return out

    # --------------------------------------------------------------- focus
    def _focus_sid(self, display_uuid, sid):
        """Switch display to space sid. SLS set + hide old; may leave visual
        artifacts on macOS 15+ — MC click is the reliable fallback."""
        old = self.sls_managed_current(display_uuid)
        ok = self.sls.set_active_space(display_uuid, sid)
        if ok and old and old != sid:
            self.sls.hide_spaces([old])
        time.sleep(0.2)
        return ok

    def sls_managed_current(self, display_uuid):
        s = next(
            (x for x in self.sls.spaces()
             if x["display_uuid"] == display_uuid and x["active"]),
            None,
        )
        return s["id"] if s else None

    def phase_focus(self, disp_map):
        for sd in self.snap["displays"]:
            cur = disp_map[sd["uuid"]]
            if cur is None or not sd.get("active_space"):
                continue
            sp = self._snap_space(sd["active_space"])
            if not sp:
                continue
            sid = None
            if sp["type"] == "user":
                sid = self._target_sid_for_user_space(sp["uuid"], cur["uuid"])
            else:
                wins = self._snap_space_windows(sp["uuid"])
                lw = self.live_for(wins[0]) if wins else None
                c = self._live_space_of(lw) if lw else None
                sid = c["id"] if c else None
            if sid is None or sid == self.sls_managed_current(cur["uuid"]):
                continue
            if self.o.dry_run:
                self.log("  would focus space %s on display %s"
                         % (sid, (cur["uuid"] or "?")[:8]))
                continue
            if self.o.focus_mode == "sls":
                self._focus_sid(cur["uuid"], sid)
            else:
                if sid in self.space_by_id:
                    if not mc.focus_space(
                        cur["frame"], self.space_by_id[sid]["index"], self.log
                    ):
                        self.failed.append(
                            "could not focus space %s on display %s"
                            % (sid, (cur["uuid"] or "?")[:8])
                        )

    # ------------------------------------------------------------------ run
    def run(self):
        if not ax.trusted():
            if self.o.dry_run:
                self.log("note: Accessibility not granted — dry-run only,"
                         " no changes will be made anyway.")
            else:
                ax.prompt_trusted()  # native "grant access" dialog
                for _ in range(30):  # grace period if granted right now
                    if ax.trusted():
                        break
                    time.sleep(1)
                if not ax.trusted():
                    self.log("ERROR: Accessibility permission required.")
                    self.log("  System Settings → Privacy & Security"
                             " → Accessibility")
                    self.log("  → enable the app/terminal running this.")
                    return 2

        disp_map = self._disp_map()

        if self.o.launch:
            self._launch_missing_apps()

        self.match_windows()
        if self.missing:
            self.log("unavailable windows (%d):" % len(self.missing))
            for w in self.missing:
                self.log("  - %s: %s" % (w["app"], w.get("title") or "—"))

        self.phase_spaces(disp_map)
        self.phase_assign_spaces(disp_map)
        self.phase_frames(disp_map)
        if self.o.fullscreen:
            self.phase_fullscreen(disp_map)
        self.phase_tiled(disp_map)
        self.phase_order(disp_map)
        self.phase_focus(disp_map)

        if self.failed:
            self.log("\ncould not fully restore:")
            for f in self.failed:
                self.log("  - %s" % f)
        self.log("\ndone.")
        return 0

    def _launch_missing_apps(self):
        running = {w["app"] for w in self.live_windows}
        for app in sorted({w["app"] for w in self.snap["windows"]} - running):
            self.log("  launching %s" % app)
            if not self.o.dry_run:
                subprocess.run(["open", "-a", app], capture_output=True)
        if not self.o.dry_run:
            time.sleep(2.5)
            self.refresh()


def sp_type_id(name):
    return {"user": 0, "fullscreen": 4, "tiled": 5}.get(name)


def load_snapshot(path):
    with open(path) as f:
        snap = json.load(f)
    if snap.get("version") != model.SNAPSHOT_VERSION:
        raise ValueError("unsupported snapshot version %r" % snap.get("version"))
    return snap
