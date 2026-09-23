"""rememoru — snapshot & restore macOS window layouts (spaces, fullscreen,
split-view, multi-display) with SIP enabled.

Commands:
  doctor       check permissions, settings and API availability
  list         show the current display/space/window layout
  snapshot     capture the current layout to a JSON file
  restore      restore a snapshot (see --help; --dry-run first!)
  inspect-mc   dump the Mission Control accessibility tree (debugging)
"""
import argparse
import json
import platform
import subprocess
import sys
import time

from . import ax, cg, mc, model, skylight
from .restore import Restorer, load_snapshot

DEFAULT_SNAPSHOT = "rememoru-snapshot.json"


def _opts(args):
    class O(object):
        pass
    o = O()
    o.verbose = args.verbose
    o.dry_run = args.dry_run
    o.launch = args.launch
    fb = args.move_fallback
    o.move_fallback = (
        {"mc", "relaunch"} if fb == "all" else {fb} if fb != "none" else set()
    )
    if args.relaunch:
        o.move_fallback.add("relaunch")
    o.fullscreen = not args.no_fullscreen
    o.split = not args.no_split
    o.reorder = not args.no_reorder
    o.remap_displays = args.remap_displays
    o.focus_mode = args.focus_mode
    return o


def cmd_doctor(_args):
    print("rememoru doctor\n")
    print("platform:      %s" % platform.platform())
    print("macOS:         %s" % (platform.mac_ver()[0] or "?"))
    print("python:        %s" % sys.version.split()[0])
    if sys.platform != "darwin":
        print("\nThis tool only runs on macOS — native APIs unavailable here.")
        print("\nSkyLight bindings:")
        for name, ok in skylight.available_symbols().items():
            print("  %-36s %s" % (name, "ok" if ok else "MISSING"))
        return 1
    try:
        sip = subprocess.run(
            ["csrutil", "status"], capture_output=True, text=True
        ).stdout.strip()
    except OSError:
        sip = "?"
    print("SIP:           %s" % sip)

    trusted = ax.trusted()
    print("accessibility: %s"
          % ("granted" if trusted else "NOT GRANTED — required for restore"))
    sr = cg.has_screen_recording()
    print("screen rec.:   %s"
          % ("granted" if sr else "not granted — window titles will be empty"
             if sr is not None else "n/a"))
    try:
        spans = subprocess.run(
            ["defaults", "read", "com.apple.spaces", "spans-displays"],
            capture_output=True, text=True,
        ).stdout.strip()
    except OSError:
        spans = ""
    sep = spans != "1"
    print("separate spaces per display: %s"
          % ("yes" if sep else "NO — enable in System Settings → Desktop & Dock"))

    print("CGDisplayCreateUUIDFromDisplayID: %s"
          % ("ok" if cg.CGDisplayCreateUUIDFromDisplayID else "MISSING"))

    print("\nSkyLight bindings:")
    for name, ok in skylight.available_symbols().items():
        print("  %-36s %s" % (name, "ok" if ok else "MISSING"))
    dock = mc.dock_pid()
    print("\nDock pid:      %s" % (dock or "not found"))
    if not trusted:
        print("\nGrant Accessibility to your terminal app, then re-run doctor.")
        return 1
    return 0


def cmd_check_ax(_args):
    """Exit 0 if this process has Accessibility permission — used by the
    login app (TCC attributes the check to the app itself) and scripts."""
    return 0 if ax.trusted() else 1


def cmd_list(_args):
    sls = skylight.Connection()
    displays = model.display_list(sls, log=print)
    spaces = sls.spaces()
    wins = model.current_windows(sls)
    by_space = {}
    for w in wins:
        by_space.setdefault(w.get("space_id"), []).append(w)
    for d in displays:
        print("display %s%s  %.0fx%.0f @ (%.0f,%.0f)"
              % ((d["uuid"] or "?")[:8], " [main]" if d["main"] else "",
                 d["frame"]["w"], d["frame"]["h"],
                 d["frame"]["x"], d["frame"]["y"]))
        for s in [s for s in spaces if s["display_uuid"] == d["uuid"]]:
            if s["type"] == 2:
                continue
            ws = by_space.get(s["id"], [])
            marker = "→" if s["active"] else " "
            print(" %s space %-7s  %-10s  %s"
                  % (marker, str(s["index"]), s["type_name"],
                     (s["uuid"] or "")[:8]))
            for w in ws:
                print("      %s: %s" % (w["app"], w["title"] or "—"))
    return 0


def cmd_snapshot(args):
    try:
        snap = model.capture(log=print)
    except Exception as e:
        print("capture failed: %s" % e)
        print("(run `./rememoru-cli doctor` to check your setup)")
        return 1
    path = args.output or _timestamped_path()
    with open(path, "w") as f:
        json.dump(snap, f, indent=2)
    nw = len(snap["windows"])
    ns = len(snap["spaces"])
    nd = len(snap["displays"])
    nfs = sum(1 for s in snap["spaces"] if s["type"] == "fullscreen")
    nsv = sum(1 for s in snap["spaces"] if s["type"] == "tiled")
    print("saved %d window(s), %d space(s) (%d fullscreen, %d split-view) "
          "on %d display(s)\n→ %s" % (nw, ns, nfs, nsv, nd, path))
    if not cg.has_screen_recording():
        print("note: Screen Recording permission not granted — window titles "
              "were not captured; restore matching will be weaker.")
    return 0


def _timestamped_path():
    return "rememoru-%s.json" % time.strftime("%Y%m%d-%H%M%S")


def cmd_restore(args):
    try:
        snap = load_snapshot(args.snapshot)
    except (OSError, ValueError) as e:
        print("cannot load snapshot: %s" % e)
        return 1
    r = Restorer(snap, _opts(args))
    return r.run()


def cmd_dump(args):
    """Raw SkyLight display/space dicts + CG displays — debugging data."""
    sls = skylight.Connection()
    print("=== SLSCopyManagedDisplaySpaces ===")
    print(json.dumps(sls.managed_displays(), indent=2, default=str))
    print("=== cg.displays ===")
    print(json.dumps(cg.displays(), indent=2, default=str))
    sls.spaces()  # populate tile_parents
    wins = cg.window_list()
    sample = [
        {
            "id": int(w.get("kCGWindowNumber") or 0),
            "app": w.get("kCGWindowOwnerName"),
            "title": w.get("kCGWindowName"),
            "pid": w.get("kCGWindowOwnerPID"),
        }
        for w in wins[: args.windows]
    ]
    wids = [w["id"] for w in sample]
    raw = sls.spaces_for_windows_raw(wids)
    print("=== SLSCopySpacesForWindows (first %d windows) ==="
          % len(sample))
    print("window count: %d, result count: %d" % (len(wids), len(raw)))
    print(json.dumps([
        {"wid": w["id"], "app": w["app"], "title": w["title"],
         "pid": w["pid"], "raw": r}
        for w, r in zip(sample, raw)
    ] + [w for w in sample[len(raw):]], indent=2, default=str))
    return 0


def cmd_inspect_mc(args):
    if not ax.trusted():
        print("Accessibility permission required first.")
        return 1
    print("opening Mission Control…")
    if not mc.open_mc():
        print("could not open Mission Control")
        return 1
    time.sleep(0.5)
    dock = mc.dock_element()
    interesting = []

    def keep(el):
        ident = ax.attr(el, "AXIdentifier")
        role = ax.attr(el, "AXRole")
        return ident or role in ("AXButton", "AXList", "AXWindow", "AXCheckBox")

    def walk(el, depth):
        if depth > args.depth:
            return
        try:
            d = ax.describe(el)
            if keep(el):
                interesting.append((depth, d))
            for c in ax.children(el):
                walk(c, depth + 1)
        except Exception:
            pass

    walk(dock, 0)
    for depth, d in interesting:
        f = d.get("frame") or {}
        print("%s%s role=%s sub=%s id=%s title=%r desc=%r f=%s" % (
            "  " * depth,
            "•", d.get("role"), d.get("subrole"), d.get("identifier"),
            d.get("title"), d.get("description"),
            "x%.0f y%.0f %.0fx%.0f" % (
                f.get("x", 0), f.get("y", 0), f.get("w", 0), f.get("h", 0)),
        ))
    mc.close_mc()
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(
        prog="rememoru",
        description="Snapshot & restore macOS window layouts across "
                    "displays, Spaces, fullscreen and Split View — "
                    "with SIP enabled.",
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("doctor", help="check permissions and API availability")
    sub.add_parser("check-ax",
                   help="exit 0 iff this process has Accessibility "
                        "permission (for scripts/login app)")
    sub.add_parser("list", help="show current display/space/window layout")

    ps = sub.add_parser("snapshot", help="capture current layout to JSON")
    ps.add_argument("-o", "--output", metavar="FILE",
                    help="output file (default: rememoru-<timestamp>.json)")

    pr = sub.add_parser("restore", help="restore a snapshot")
    pr.add_argument("snapshot", nargs="?", default=DEFAULT_SNAPSHOT)
    pr.add_argument("--dry-run", action="store_true",
                    help="print the plan without changing anything")
    pr.add_argument("--verbose", "-v", action="store_true")
    pr.add_argument("--launch", action="store_true",
                    help="launch apps that have no running windows")
    pr.add_argument("--relaunch", action="store_true",
                    help="allow quit+reopen as a window-move fallback "
                         "(may lose unsaved app state)")
    pr.add_argument("--move-fallback",
                    choices=["none", "mc", "relaunch", "all"],
                    default="mc",
                    help="fallback if the bridged space-move fails: "
                         "Mission Control drag and/or app relaunch "
                         "(default: mc)")
    pr.add_argument("--no-fullscreen", action="store_true",
                    help="do not recreate fullscreen spaces")
    pr.add_argument("--no-split", action="store_true",
                    help="do not recreate split-view pairs")
    pr.add_argument("--no-reorder", action="store_true",
                    help="do not reorder space thumbnails")
    pr.add_argument("--remap-displays", action="store_true",
                    help="map missing displays to connected ones")
    pr.add_argument("--focus-mode", choices=["sls", "mc"], default="sls",
                    help="how to switch active spaces: fast SkyLight call "
                         "(may need a manual swipe to repaint on macOS 15+) "
                         "or Mission Control click (default: sls)")

    pi = sub.add_parser("inspect-mc",
                        help="dump Dock/Mission Control AX tree")
    pi.add_argument("--depth", type=int, default=14)

    pd = sub.add_parser(
        "dump",
        help="dump raw SkyLight/CG display+space data (debugging)")
    pd.add_argument("--windows", type=int, default=60,
                    help="how many windows to include in the "
                         "SLSCopySpacesForWindows section (default: 60)")

    args = p.parse_args(argv)
    if args.cmd != "doctor" and sys.platform != "darwin":
        print("rememoru only runs on macOS (this is %s)." % sys.platform)
        return 1
    return {
        "doctor": cmd_doctor,
        "check-ax": cmd_check_ax,
        "list": cmd_list,
        "snapshot": cmd_snapshot,
        "restore": cmd_restore,
        "inspect-mc": cmd_inspect_mc,
        "dump": cmd_dump,
    }[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
