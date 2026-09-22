"""Mission Control UI automation.

Everything here works with SIP enabled. The Dock exposes the Mission
Control UI through its accessibility tree — notably the spaces bar with
AXIdentifier "mc.spaces.list" (ordered space thumbnails) and the add-space
button "mc.spaces.add" (identifiers used by jdtsmith/SplitView).
"""
import subprocess
import time

from . import ax, cg


def dock_pid():
    try:
        out = subprocess.run(
            ["pgrep", "-x", "Dock"], capture_output=True, text=True, timeout=5
        )
        return int(out.stdout.strip().split()[0])
    except Exception:
        return None


def dock_element():
    pid = dock_pid()
    return ax.app_element(pid) if pid else None


# --- generic AX tree search -------------------------------------------------

def find_all(root, pred, max_depth=30, max_nodes=4000):
    """BFS over an AX subtree; returns elements where pred(el) is True."""
    found = []
    queue = [(root, 0)]
    seen = 0
    while queue and seen < max_nodes:
        el, depth = queue.pop(0)
        seen += 1
        if el is None or depth > max_depth:
            continue
        try:
            if pred(el):
                found.append(el)
            if depth < max_depth:
                for c in ax.children(el):
                    queue.append((c, depth + 1))
        except Exception:
            continue
    return found


def find_by_identifier(root, ident):
    return find_all(root, lambda el: ax.attr(el, "AXIdentifier") == ident)


def _frame_in_display(el, display_frame, margin=1.0):
    f = ax.frame(el)
    if not f or not display_frame:
        return False
    cx, cy = f["x"] + f["w"] / 2.0, f["y"] + f["h"] / 2.0
    d = display_frame
    return (
        d["x"] - margin <= cx <= d["x"] + d["w"] + margin
        and d["y"] - margin <= cy <= d["y"] + d["h"] + margin
    )


# --- Mission Control lifecycle ----------------------------------------------

def open_mc(timeout=4.0):
    subprocess.run(["open", "-a", "Mission Control"], capture_output=True)
    dock = dock_element()
    if dock is None:
        return False
    deadline = time.time() + timeout
    while time.time() < deadline:
        if find_by_identifier(dock, "mc.spaces.list"):
            return True
        time.sleep(0.1)
    return False


def close_mc():
    cg.key(cg.KEY_ESCAPE)
    time.sleep(0.3)


def _spaces_list_for_display(dock, display_frame):
    for el in find_by_identifier(dock, "mc.spaces.list"):
        if _frame_in_display(el, display_frame):
            return el
    return None


def space_buttons(display_frame):
    """Ordered space-thumbnail elements for one display (MC must be open).
    Order matches the SLS space order for that display."""
    dock = dock_element()
    if dock is None:
        return []
    lst = _spaces_list_for_display(dock, display_frame)
    if lst is None:
        return []
    return ax.children(lst)


def add_space_button(display_frame):
    dock = dock_element()
    if dock is None:
        return None
    lst = _spaces_list_for_display(dock, display_frame)
    if lst is None:
        return None
    parent = ax.attr_ref(lst, "AXParent")
    for sib in ax.children(parent):
        if ax.attr(sib, "AXIdentifier") == "mc.spaces.add":
            return sib
    return None


def reveal_spaces_bar(display_frame):
    """The '+' button only appears when the pointer nears the spaces bar."""
    x = display_frame["x"] + display_frame["w"] * 0.9
    cg.move_mouse(x, display_frame["y"] + 6)
    time.sleep(0.4)


def create_spaces(display_frame, count, log, settle=0.6):
    """Create `count` new desktop spaces on a display. MC must be open.
    Returns number actually created."""
    created = 0
    for _ in range(count):
        before = len(space_buttons(display_frame))
        btn = add_space_button(display_frame)
        if btn is None:
            reveal_spaces_bar(display_frame)
            btn = add_space_button(display_frame)
        if btn is None:
            log("  ! could not find the '+' button in Mission Control")
            break
        if not ax.press(btn):
            c = ax.center(btn)
            if c:
                cg.click(*c)
        deadline = time.time() + 5
        while time.time() < deadline:
            time.sleep(0.15)
            if len(space_buttons(display_frame)) > before:
                break
        if len(space_buttons(display_frame)) <= before:
            log("  ! '+' click did not create a space")
            break
        created += 1
        time.sleep(settle)
    return created


def remove_space_button(btn):
    return ax.perform(btn, "AXRemoveDesktop")


def click_space_button(btn):
    if ax.press(btn):
        return True
    c = ax.center(btn)
    if c:
        cg.click(*c)
        return True
    return False


# --- reordering --------------------------------------------------------------

def reorder_spaces(display_frame, desired_ids, current_ids_fn, log):
    """Drag space thumbnails so the order matches desired_ids.

    desired_ids: live space ids in the order the snapshot wants (a prefix;
    extra spaces may follow). current_ids_fn(): callable re-queried after
    every drag; returns the display's current ordered space ids. The i-th
    Mission Control thumbnail corresponds to the i-th id.
    Best-effort: returns True if the order matched afterwards.
    """
    for _ in range(3 * len(desired_ids) + 4):
        order = current_ids_fn()
        if order[: len(desired_ids)] == desired_ids:
            return True
        i = next(
            (k for k in range(len(desired_ids))
             if k >= len(order) or order[k] != desired_ids[k]),
            None,
        )
        if i is None:
            return True
        if desired_ids[i] not in order:
            log("  ! a desired space no longer exists; giving up")
            return False
        j = order.index(desired_ids[i])
        buttons = space_buttons(display_frame)
        if len(buttons) != len(order):
            # spaces without thumbnails (e.g. Dashboard) shift indices —
            # drags could hit the wrong thumbnail
            log("  ! %d thumbnails vs %d spaces — index parity unsure"
                % (len(buttons), len(order)))
        if i >= len(buttons) or j >= len(buttons):
            return False
        src = ax.center(buttons[j])
        dst = ax.center(buttons[i])
        if not src or not dst:
            return False
        log("  dragging space thumbnail %d -> %d" % (j, i))
        cg.drag(src[0], src[1], dst[0], dst[1])
        time.sleep(0.6)
    order = current_ids_fn()
    return order[: len(desired_ids)] == desired_ids


# --- window thumbnails (for cross-space drags) -------------------------------

def find_window_thumbnail(display_frame, title, spaces_bar_bottom):
    """Find the MC thumbnail element for a window on the shown space."""
    dock = dock_element()
    if dock is None or not title:
        # without a title every thumbnail matches — moving a random window
        # is worse than failing
        return None

    def matches(el):
        t = ax.attr(el, "AXTitle") or ax.attr(el, "AXDescription") or ""
        if title not in t:
            return False
        f = ax.frame(el)
        if not f or f["h"] < 20:  # thumbnails are substantial
            return False
        return _frame_in_display(el, display_frame) and f["y"] > spaces_bar_bottom

    hits = find_all(dock, matches)
    return hits[0] if hits else None


def drag_window_to_space(display_frame, win_title, target_btn, log):
    """Move a window to another space by dragging its MC thumbnail onto the
    target space's thumbnail. The window's current space must be the active
    one on that display."""
    buttons = space_buttons(display_frame)
    if not buttons:
        return False
    bar_bottom = max(
        (ax.frame(b) or {"y": 0, "h": 0})["y"] + (ax.frame(b) or {"h": 0})["h"]
        for b in buttons
    )
    thumb = find_window_thumbnail(display_frame, win_title, bar_bottom)
    if thumb is None:
        log("  ! window thumbnail for %r not found in Mission Control" % win_title)
        return False
    src = ax.center(thumb)
    dst = ax.center(target_btn)
    cg.drag(src[0], src[1], dst[0], dst[1], steps=18)
    return True


# --- focus -------------------------------------------------------------------

def focus_space(display_frame, space_index, log):
    """Switch a display to space #index by clicking its MC thumbnail."""
    if not open_mc():
        log("  ! could not open Mission Control")
        return False
    buttons = space_buttons(display_frame)
    ok = False
    if space_index < len(buttons):
        ok = click_space_button(buttons[space_index])
    if not ok:
        close_mc()
    return ok


# --- Split View ---------------------------------------------------------------

_TILE_TITLE_EXACT = {"left": "Left of Screen", "right": "Right of Screen"}
_TILE_TITLE_CONTAINS = {
    "left": ("Tile Window to Left", "Left of Screen"),
    "right": ("Tile Window to Right", "Right of Screen"),
}


def _pick_tile_menu_item(zoom_el, side, log, attempts=6):
    """While the green button is held, its children contain a menu with
    tiling items. Find and AXPress the right one.

    macOS 15+ nests the items under a "Full Screen" submenu that may only
    populate once opened — so we press that first if no direct hit."""
    wanted_exact = _TILE_TITLE_EXACT[side]
    contains = _TILE_TITLE_CONTAINS[side]
    items = []
    opened_submenu = False
    for _ in range(attempts):
        items = ax.menu_items_under(zoom_el)
        for mi in items:
            if (ax.attr(mi, "AXTitle") or "") == wanted_exact:
                if ax.press(mi):
                    return True
        for mi in items:
            t = ax.attr(mi, "AXTitle") or ""
            if "Desktop" in t:
                continue
            if any(c in t for c in contains):
                if ax.press(mi):
                    return True
        if not opened_submenu:
            for mi in items:
                if (ax.attr(mi, "AXTitle") or "") == "Full Screen":
                    ax.press(mi)          # opens the submenu
                    opened_submenu = True
                    time.sleep(0.3)
                    break
            if not opened_submenu:
                break                     # no tiling items and no submenu
        time.sleep(0.1)
    if items:
        log("  ! zoom menu items seen: %r"
            % [ax.attr(i, "AXTitle") for i in items])
    return False


def _wait(predicate, timeout, interval=0.08):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return False


def _window_matches(el, pid, title):
    win = ax.window_of(el)
    if win is None:
        return False
    if ax.pid_of(win) != pid:
        return False
    wt = ax.attr(win, "AXTitle") or ""
    return (not title) or wt == title or title in wt or wt in title


def _find_mini_window(display_frame, occupied_half, pid, title, log,
                      grid_n=6, max_iter=3):
    """Grid-search the empty half of the split-view picker for the miniature
    of the companion window (jdtsmith/SplitView technique)."""
    d = display_frame
    half = {
        "x": d["x"] + (d["w"] / 2.0 if occupied_half == "left" else 0.0),
        "y": d["y"],
        "w": d["w"] / 2.0,
        "h": d["h"],
    }
    m = max(1, int(round(half["h"] / half["w"] * grid_n)))
    jiggles = [(0.5, 0.5)]
    for it in range(max_iter):
        for jx, jy in jiggles:
            for i in range(1, grid_n + 1):
                for j in range(1, m + 1):
                    x = half["x"] + (i - jx) * half["w"] / grid_n
                    y = half["y"] + (j - jy) * half["h"] / m
                    el = ax.element_at(x, y)
                    if el and _window_matches(el, pid, title):
                        return (x, y)
        # refine the grid
        step = 0.5 / (2 ** it)
        new = []
        for jx, jy in jiggles:
            for dx in (-1, 1):
                for dy in (-1, 1):
                    new.append((jx + dx * step, jy + dy * step))
        jiggles = new
    return None


def split_view(win_el, win_pid, win_title, side,
               other_pid, other_title, display_frame, log,
               menu_timeout=1.8, pick_timeout=6.0):
    """Automate the Split View UI: hold the green button, pick
    '<side> of Screen', then click the companion window's miniature.

    Returns True if the picker click was dispatched."""
    zb = ax.zoom_button(win_el)
    if zb is None:
        log("  ! no zoom/fullscreen button found on window")
        return False
    pt = ax.center(zb)
    if not pt:
        return False

    log("  holding zoom button at (%.0f, %.0f)" % pt)
    cg.mouse_down(*pt)
    time.sleep(0.15)

    if not _wait(lambda: bool(ax.children(zb)), menu_timeout):
        log("  ! zoom menu never appeared; releasing")
        cg.mouse_up(*pt)
        return False
    if not _pick_tile_menu_item(zb, side, log):
        log("  ! no tiling item found; releasing")
        cg.mouse_up(*pt)
        return False
    cg.mouse_up(*pt)  # the tile action was dispatched; release the hold

    # window goes fullscreen on its half; then the picker shows the rest
    landed = _wait(lambda: ax.is_fullscreen(win_el), 2.5)
    if not landed:
        f = ax.frame(win_el)
        if f and abs(f["h"] - display_frame["h"]) < 4:
            landed = True
    if not landed:
        log("  ! window did not enter fullscreen; aborting pick")
        return False

    f = ax.frame(win_el) or {}
    occupied = "left" if f.get("x", 1e9) <= display_frame["x"] + 2 else "right"
    log("  window tiled on %s; searching for companion miniature" % occupied)

    time.sleep(0.4)  # let the picker settle
    deadline = time.time() + pick_timeout
    while time.time() < deadline:
        pos = _find_mini_window(display_frame, occupied, other_pid, other_title, log)
        if pos:
            log("  clicking companion miniature at (%.0f, %.0f)" % pos)
            cg.click(*pos)
            return True
        time.sleep(0.3)
    log("  ! companion window not found in picker — click it manually")
    return False
