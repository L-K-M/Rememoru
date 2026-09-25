import XCTest
@testable import RememoruCore

final class RestorePlannerTests: XCTestCase {
    private let screen = Rect(x: 0, y: 0, w: 1920, h: 1080)

    private func snapshot(spaces: [(String, SpaceKind)], active: String? = nil,
                          windows: [WindowRecord]) -> Snapshot {
        Snapshot(
            created: "",
            displays: [DisplayRecord(uuid: "D", frame: screen, isMain: true,
                                     spaceUUIDs: spaces.map(\.0), activeSpaceUUID: active)],
            spaces: spaces.enumerated().map { index, space in
                SpaceRecord(uuid: space.0, id: UInt64(index + 100), kind: space.1,
                            displayUUID: "D", index: index, isActive: space.0 == active)
            },
            windows: windows
        )
    }

    private func saved(_ id: UInt32, on space: String, side: SplitSide? = nil,
                       frame: Rect = Rect(x: 10, y: 30, w: 800, h: 600)) -> WindowRecord {
        WindowRecord(windowID: id, pid: Int32(id), appName: "App\(id)", bundleID: nil, title: "w\(id)",
                     frame: frame, spaceUUID: space, displayUUID: "D", splitSide: side)
    }

    private func live(desktops: Int, extra: [LiveSpace] = [], windows: [LiveWindow],
                      display: Rect? = nil) -> LiveState {
        var spaces = (0..<desktops).map {
            LiveSpace(id: UInt64($0 + 1), key: "L\($0)", kind: .desktop, displayUUID: "D",
                      index: $0, isActive: $0 == 0)
        }
        spaces += extra
        return LiveState(
            displays: [LiveDisplay(id: 1, uuid: "D", frame: display ?? screen, isMain: true)],
            spaces: spaces, windows: windows
        )
    }

    private func window(_ id: UInt32, space: UInt64?, frame: Rect = Rect(x: 10, y: 30, w: 800, h: 600),
                        minimized: Bool = false) -> LiveWindow {
        LiveWindow(id: id, pid: Int32(id), appName: "App\(id)", title: "w\(id)", frame: frame,
                   isOnscreen: true, spaceID: space, isMinimized: minimized)
    }

    private func plan(_ snap: Snapshot, _ state: LiveState,
                      options: RestoreOptions = RestoreOptions()) -> RestorePlan {
        RestorePlanner.plan(snapshot: snap, live: state,
                            matches: WindowMatcher.match(snap.windows, to: state.windows), options: options)
    }

    func testAlreadyRestoredLayoutNeedsNoSteps() {
        let snap = snapshot(spaces: [("a", .desktop), ("b", .desktop)], windows: [saved(1, on: "b")])
        let result = plan(snap, live(desktops: 2, windows: [window(1, space: 2)]),
                          options: { var o = RestoreOptions(); o.focus = false; return o }())
        XCTAssertEqual(result.steps, [])
        XCTAssertEqual(result.unmatched, [])
    }

    func testCreatesMissingDesktopsThenMovesAndFrames() {
        let target = Rect(x: 100, y: 100, w: 700, h: 500)
        let snap = snapshot(spaces: [("a", .desktop), ("b", .desktop), ("c", .desktop)],
                            windows: [saved(1, on: "c", frame: target)])
        let state = live(desktops: 1, windows: [window(1, space: 1)])
        let steps = plan(snap, state).steps
        let ref = WindowTarget(state.windows[0])
        XCTAssertEqual(Array(steps.prefix(3)), [
            .createDesktops(display: "D", count: 2),
            .setFrame(ref, target),
            .moveToDesktop(ref, display: "D", ordinal: 2),
        ])
    }

    func testWindowInFullscreenLeavesItBeforeMoving() {
        let snap = snapshot(spaces: [("a", .desktop)], windows: [saved(1, on: "a")])
        let fs = LiveSpace(id: 50, key: "fs", kind: .fullscreen, displayUUID: "D", index: 1, isActive: false)
        let state = live(desktops: 1, extra: [fs], windows: [window(1, space: 50, frame: screen)])
        let steps = plan(snap, state).steps
        XCTAssertEqual(steps.first, .exitFullscreen(WindowTarget(state.windows[0])))
        XCTAssertTrue(steps.contains(.moveToDesktop(WindowTarget(state.windows[0]), display: "D", ordinal: 0)))
    }

    func testFullscreenSpacesAnchoredToTheSameDesktopAreCreatedLastFirst() {
        // Mission Control order: D1, F1, D2, S1, F2
        let snap = snapshot(
            spaces: [("d1", .desktop), ("f1", .fullscreen), ("d2", .desktop), ("s1", .splitView), ("f2", .fullscreen)],
            windows: [saved(1, on: "f1"), saved(2, on: "s1", side: .left), saved(3, on: "s1", side: .right),
                      saved(4, on: "f2")]
        )
        let state = live(desktops: 2, windows: [1, 2, 3, 4].map { window($0, space: 1) })
        let steps = plan(snap, state).steps.filter {
            if case .enterFullscreen = $0 { return true }
            if case .splitView = $0 { return true }
            if case .arrangeSpaces = $0 { return true }
            return false
        }
        let refs = state.windows.map(WindowTarget.init)
        XCTAssertEqual(steps, [
            .enterFullscreen(refs[0], display: "D", anchorOrdinal: 0),
            .enterFullscreen(refs[3], display: "D", anchorOrdinal: 1),
            .splitView(left: refs[1], right: refs[2], display: "D", anchorOrdinal: 1),
            .arrangeSpaces(snapshotDisplay: "D", display: "D"),
        ])
    }

    func testExistingFullscreenAndSplitSpacesAreKept() {
        let snap = snapshot(spaces: [("d1", .desktop), ("f1", .fullscreen), ("s1", .splitView)],
                            windows: [saved(1, on: "f1"), saved(2, on: "s1", side: .left),
                                      saved(3, on: "s1", side: .right)])
        let state = live(
            desktops: 1,
            extra: [LiveSpace(id: 60, key: "x", kind: .fullscreen, displayUUID: "D", index: 1, isActive: false),
                    LiveSpace(id: 61, key: "y", kind: .splitView, displayUUID: "D", index: 2, isActive: false)],
            windows: [window(1, space: 60), window(2, space: 61), window(3, space: 61)]
        )
        let steps = plan(snap, state, options: { var o = RestoreOptions(); o.focus = false; return o }()).steps
        XCTAssertEqual(steps, [.arrangeSpaces(snapshotDisplay: "D", display: "D")],
                       "existing spaces are kept; only their order is checked")
    }

    func testDesktopOnlyLayoutsNeedNoArranging() {
        let snap = snapshot(spaces: [("a", .desktop), ("b", .desktop)], windows: [])
        XCTAssertFalse(plan(snap, live(desktops: 1, windows: [])).steps.contains {
            if case .arrangeSpaces = $0 { return true }
            return false
        })
    }

    func testSplitViewPairWithMissingWindowIsReported() {
        let snap = snapshot(spaces: [("d1", .desktop), ("s1", .splitView)],
                            windows: [saved(1, on: "s1", side: .left), saved(2, on: "s1", side: .right)])
        let result = plan(snap, live(desktops: 1, windows: [window(1, space: 1)]))
        XCTAssertFalse(result.steps.contains { if case .splitView = $0 { return true }; return false })
        XCTAssertEqual(result.unmatched.map(\.windowID), [2])
        XCTAssertTrue(result.notes.contains { $0.contains("split view") })
    }

    func testFocusTargetsDesktopOrdinalOrFullscreenWindow() {
        let desk = snapshot(spaces: [("a", .desktop), ("b", .desktop)], active: "b", windows: [])
        XCTAssertEqual(plan(desk, live(desktops: 2, windows: [])).steps,
                       [.focus(display: "D", .desktop(ordinal: 1))])

        let full = snapshot(spaces: [("a", .desktop), ("f", .fullscreen)], active: "f",
                            windows: [saved(1, on: "f")])
        let steps = plan(full, live(desktops: 1, windows: [window(1, space: 1)])).steps
        XCTAssertEqual(steps.last, .focus(display: "D", .spaceOf(window: 1)))
    }

    func testMinimizedStateIsRestored() {
        var minimized = saved(1, on: "a")
        minimized.isMinimized = true
        let snap = snapshot(spaces: [("a", .desktop)], windows: [minimized, saved(2, on: "a")])
        let state = live(desktops: 1, windows: [window(1, space: 1), window(2, space: nil, minimized: true)])
        let steps = plan(snap, state, options: { var o = RestoreOptions(); o.focus = false; return o }()).steps
        XCTAssertEqual(steps.first, .setMinimized(WindowTarget(state.windows[0]), true))
        XCTAssertTrue(steps.contains(.setMinimized(WindowTarget(state.windows[1]), false)))
    }

    func testDisconnectedDisplayIsSkippedUnlessFallbackRequested() {
        var snap = snapshot(spaces: [("a", .desktop)], windows: [saved(1, on: "a")])
        snap.displays[0].uuid = "GONE"
        snap.spaces[0].displayUUID = "GONE"
        snap.windows[0].displayUUID = "GONE"
        let state = live(desktops: 1, windows: [window(1, space: 1, frame: Rect(x: 500, y: 500, w: 800, h: 600))])

        let skipped = plan(snap, state)
        XCTAssertEqual(skipped.steps, [])
        XCTAssertTrue(skipped.notes.contains { $0.contains("not connected") })

        var options = RestoreOptions()
        options.displayFallback = .mainDisplay
        XCTAssertTrue(plan(snap, state, options: options).steps.contains {
            if case .setFrame = $0 { return true }
            return false
        })
    }

    func testAppsToLaunchAreThoseWithoutLiveWindows() {
        var mail = saved(1, on: "a")
        mail.bundleID = "com.apple.mail"
        var notes = saved(2, on: "a")
        notes.bundleID = "com.apple.Notes"
        var notes2 = saved(3, on: "a")
        notes2.bundleID = "com.apple.Notes"
        let snap = snapshot(spaces: [("a", .desktop)], windows: [mail, notes, notes2, saved(4, on: "a")])
        var running = window(9, space: 1)
        running.bundleID = "com.apple.mail"
        XCTAssertEqual(RestorePlanner.appsToLaunch(snapshot: snap, live: live(desktops: 1, windows: [running])),
                       ["com.apple.Notes": 2])
    }

    func testTranslateKeepsRelativePositionAndClampsToSmallerDisplays() {
        let old = Rect(x: 0, y: 0, w: 2560, h: 1440)
        XCTAssertEqual(RestorePlanner.translate(Rect(x: 100, y: 50, w: 800, h: 600),
                                                from: old, to: Rect(x: -2560, y: 0, w: 2560, h: 1440)),
                       Rect(x: -2460, y: 50, w: 800, h: 600))
        XCTAssertEqual(RestorePlanner.translate(Rect(x: 2000, y: 1000, w: 2000, h: 600),
                                                from: old, to: Rect(x: 0, y: 0, w: 1440, h: 900)),
                       Rect(x: 0, y: 300, w: 1440, h: 600))
        XCTAssertEqual(RestorePlanner.translate(Rect(x: 2400, y: 0, w: 800, h: 600), from: old, to: old),
                       Rect(x: 2400, y: 0, w: 800, h: 600), "same display: no clamping")
    }
}
