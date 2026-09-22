"""Offline tests for the pure-Python parts of rememoru.

These run on any OS — the macOS frameworks are mocked at the module
boundary (cg.displays, skylight.Connection, model.current_windows,
ax.trusted). Run with:  python3 -m unittest tests.test_offline -v
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from rememoru import model, restore, skylight, cg, ax  # noqa: E402


class FakeConn(object):
    def __init__(self):
        pass

    def spaces_for_windows(self, wids):
        return [100] * len(wids)

    def spaces(self):
        return [
            {"id": 100, "uuid": "s1", "type": 0, "type_name": "user",
             "display_uuid": "d1", "index": 0, "active": True},
            {"id": 101, "uuid": "s2", "type": 0, "type_name": "user",
             "display_uuid": "d1", "index": 1, "active": False},
        ]

    def set_active_space(self, *a):
        return True

    def hide_spaces(self, *a):
        return True

    def move_windows_to_space(self, *a):
        return True


DISPS = [{"id": 1, "uuid": "d1",
          "frame": {"x": 0, "y": 0, "w": 1920, "h": 1080}, "main": True}]

LIVE_WINDOWS = [
    {"id": 10, "pid": 500, "app": "Safari", "bundle_id": "com.apple.Safari",
     "title": "Docs",
     "frame": {"x": 0, "y": 0, "w": 960, "h": 1080},
     "onscreen": True, "space_id": 100},
]

SNAP = {
    "version": 1, "created": "x",
    "displays": [{"uuid": "d1",
                  "frame": {"x": 0, "y": 0, "w": 1920, "h": 1080},
                  "main": True,
                  "spaces": ["s1", "s2", "s3"], "active_space": "s2"}],
    "spaces": [
        {"uuid": "s1", "id": 1, "type": "user", "display_uuid": "d1",
         "index": 0, "active": False},
        {"uuid": "s2", "id": 2, "type": "user", "display_uuid": "d1",
         "index": 1, "active": True},
        {"uuid": "s3", "id": 3, "type": "fullscreen", "display_uuid": "d1",
         "index": 2, "active": False},
    ],
    "windows": [
        {"id": 10, "pid": 500, "app": "Safari",
         "bundle_id": "com.apple.Safari", "title": "Docs",
         "frame": {"x": 0, "y": 0, "w": 960, "h": 1080},
         "onscreen": True, "space_uuid": "s1", "space_type": "user",
         "display_uuid": "d1"},
        {"id": 99, "pid": 999, "app": "Gone", "bundle_id": None,
         "title": "dead",
         "frame": {"x": 0, "y": 0, "w": 100, "h": 100},
         "onscreen": True, "space_uuid": "s2", "space_type": "user",
         "display_uuid": "d1"},
    ],
}


def opts(**kw):
    class O(object):
        pass
    o = O()
    o.verbose = kw.get("verbose", False)
    o.dry_run = kw.get("dry_run", True)
    o.launch = kw.get("launch", False)
    o.relaunch = kw.get("relaunch", False)
    o.move_fallback = kw.get("move_fallback", {"mc"})
    o.fullscreen = kw.get("fullscreen", True)
    o.split = kw.get("split", True)
    o.reorder = kw.get("reorder", True)
    o.remap_displays = kw.get("remap_displays", False)
    o.focus_mode = kw.get("focus_mode", "sls")
    return o


class CaptureTest(unittest.TestCase):
    def setUp(self):
        self._saved = (
            model.cg.displays, model.cg.window_list,
            model.skylight.Connection, model._bundle_ids,
        )
        model.cg.displays = lambda: DISPS
        model.cg.window_list = lambda onscreen_only=False: [
            {"kCGWindowNumber": 10, "kCGWindowOwnerName": "Safari",
             "kCGWindowOwnerPID": 500, "kCGWindowName": "Docs",
             "kCGWindowBounds": {"X": 0, "Y": 0, "Width": 960, "Height": 1080},
             "kCGWindowLayer": 0, "kCGWindowAlpha": 1,
             "kCGWindowIsOnscreen": True},
            {"kCGWindowNumber": 11, "kCGWindowOwnerName": "Dock",
             "kCGWindowOwnerPID": 1, "kCGWindowName": "",
             "kCGWindowBounds": {"X": 0, "Y": 0, "Width": 50, "Height": 50},
             "kCGWindowLayer": 0, "kCGWindowAlpha": 1,
             "kCGWindowIsOnscreen": True},
            {"kCGWindowNumber": 12, "kCGWindowOwnerName": "Safari",
             "kCGWindowOwnerPID": 500, "kCGWindowName": "popup",
             "kCGWindowBounds": {"X": 0, "Y": 0, "Width": 10, "Height": 10},
             "kCGWindowLayer": 25, "kCGWindowAlpha": 1,
             "kCGWindowIsOnscreen": True},
        ]
        model.skylight.Connection = FakeConn
        model._bundle_ids = lambda pids: {p: "com.test.%d" % p for p in pids}

    def tearDown(self):
        (model.cg.displays, model.cg.window_list,
         model.skylight.Connection, model._bundle_ids) = self._saved

    def test_capture_filters_and_maps(self):
        snap = model.capture(log=lambda *a: None)
        # blocklisted owner + non-zero-layer window filtered out
        self.assertEqual(len(snap["windows"]), 1)
        w = snap["windows"][0]
        self.assertEqual(w["app"], "Safari")
        self.assertEqual(w["space_uuid"], "s1")
        self.assertEqual(w["bundle_id"], "com.test.500")
        self.assertEqual(snap["displays"][0]["spaces"], ["s1", "s2"])
        self.assertEqual(snap["displays"][0]["active_space"], "s1")


class RestoreTest(unittest.TestCase):
    def setUp(self):
        self._saved = (
            restore.skylight.Connection, restore.model.current_windows,
            cg.displays, ax.trusted,
        )
        restore.skylight.Connection = FakeConn
        restore.model.current_windows = lambda sls: list(LIVE_WINDOWS)
        cg.displays = lambda: DISPS
        ax.trusted = lambda: False

    def tearDown(self):
        (restore.skylight.Connection, restore.model.current_windows,
         cg.displays, ax.trusted) = self._saved

    def test_dry_run_runs_without_ax_permission(self):
        logs = []
        r = restore.Restorer(dict(SNAP, windows=[dict(w) for w in
                                                 SNAP["windows"]]),
                             opts(dry_run=True), log=logs.append)
        self.assertEqual(r.run(), 0)
        out = "\n".join(logs)
        self.assertIn("Gone", out)          # missing window reported
        self.assertIn("dry-run", out)

    def test_matching_and_snap_space_none_guard(self):
        r = restore.Restorer(dict(SNAP, windows=[dict(w) for w in
                                                 SNAP["windows"]]),
                             opts(), log=lambda *a: None)
        r.match_windows()
        live = r.live_for(r.snap["windows"][0])
        self.assertIsNotNone(live)
        self.assertEqual(live["id"], 10)
        self.assertIsNone(r._snap_space(None))
        self.assertIs(r.live_for(r.snap["windows"][1]), None)


if __name__ == "__main__":
    unittest.main()
