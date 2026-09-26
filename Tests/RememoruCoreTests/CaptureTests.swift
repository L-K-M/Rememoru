import XCTest
@testable import RememoruCore

final class WindowFilterTests: XCTestCase {
    func testKeepsNormalWindowsOnly() {
        let info: [[String: Any]] = [
            ["kCGWindowNumber": 10, "kCGWindowOwnerName": "Safari", "kCGWindowOwnerPID": 500,
             "kCGWindowName": "Docs", "kCGWindowLayer": 0, "kCGWindowAlpha": 1, "kCGWindowIsOnscreen": true,
             "kCGWindowBounds": ["X": 0, "Y": 25, "Width": 960, "Height": 1055]],
            // system UI owner
            ["kCGWindowNumber": 11, "kCGWindowOwnerName": "Dock", "kCGWindowOwnerPID": 1,
             "kCGWindowLayer": 0, "kCGWindowBounds": ["X": 0, "Y": 0, "Width": 500, "Height": 500]],
            // floating layer
            ["kCGWindowNumber": 12, "kCGWindowOwnerName": "Safari", "kCGWindowOwnerPID": 500,
             "kCGWindowLayer": 25, "kCGWindowBounds": ["X": 0, "Y": 0, "Width": 500, "Height": 500]],
            // helper surface too small to be a window
            ["kCGWindowNumber": 13, "kCGWindowOwnerName": "Safari", "kCGWindowOwnerPID": 500,
             "kCGWindowLayer": 0, "kCGWindowBounds": ["X": 0, "Y": 0, "Width": 10, "Height": 10]],
            // fully transparent
            ["kCGWindowNumber": 14, "kCGWindowOwnerName": "Notes", "kCGWindowOwnerPID": 600,
             "kCGWindowLayer": 0, "kCGWindowAlpha": 0,
             "kCGWindowBounds": ["X": 0, "Y": 0, "Width": 500, "Height": 500]],
        ]
        let windows = WindowFilter.candidates(from: info)
        XCTAssertEqual(windows.map(\.id), [10])
        XCTAssertEqual(windows.first?.frame, Rect(x: 0, y: 25, w: 960, h: 1055))
        XCTAssertEqual(windows.first?.title, "Docs")
        XCTAssertEqual(windows.first?.isOnscreen, true)
    }
}

final class WindowMatcherTests: XCTestCase {
    private func saved(_ id: UInt32, _ app: String, _ title: String, pid: Int32 = 1,
                       x: Double = 0, bundle: String? = nil) -> WindowRecord {
        WindowRecord(windowID: id, pid: pid, appName: app, bundleID: bundle, title: title,
                     frame: Rect(x: x, y: 0, w: 800, h: 600), spaceUUID: nil, displayUUID: nil)
    }

    private func live(_ id: UInt32, _ app: String, _ title: String, pid: Int32 = 1,
                      x: Double = 0, bundle: String? = nil) -> LiveWindow {
        LiveWindow(id: id, pid: pid, appName: app, bundleID: bundle, title: title,
                   frame: Rect(x: x, y: 0, w: 800, h: 600), isOnscreen: true)
    }

    func testSameSessionWindowIdentityWins() {
        let matches = WindowMatcher.match(
            [saved(7, "Terminal", "zsh", pid: 42)],
            to: [live(8, "Terminal", "zsh", pid: 42), live(7, "Terminal", "zsh", pid: 42, x: 900)]
        )
        XCTAssertEqual(matches[0]?.live.id, 7)
        XCTAssertEqual(matches[0]?.basis, .sameWindow)
    }

    func testTitlesPairWindowsOfTheSameApp() {
        let matches = WindowMatcher.match(
            [saved(1, "Notes", "Groceries"), saved(2, "Notes", "Work")],
            to: [live(20, "Notes", "Work"), live(21, "Notes", "Groceries")]
        )
        XCTAssertEqual(matches[0]?.live.id, 21)
        XCTAssertEqual(matches[1]?.live.id, 20)
        XCTAssertEqual(matches[1]?.basis, .title)
    }

    func testChangedTitlesFallBackToNearestFrame() {
        let matches = WindowMatcher.match(
            [saved(1, "Safari", "Old tab A", x: 0), saved(2, "Safari", "Old tab B", x: 1000)],
            to: [live(30, "Safari", "New tab", x: 990), live(31, "Safari", "Other", x: 10)]
        )
        XCTAssertEqual(matches[0]?.live.id, 31)
        XCTAssertEqual(matches[1]?.live.id, 30)
        XCTAssertEqual(matches[0]?.basis, .position)
    }

    func testMissingLiveTitleDoesNotOutrankChangedTitleAtSavedFrame() {
        let record = saved(1, "Slack", "Old channel", x: 4872)
        var helper = live(20, "Slack", "", x: 0)
        helper.frame = Rect(x: 0, y: 482, w: 500, h: 500)
        let window = live(21, "Slack", "New channel", x: 4872)

        let matches = WindowMatcher.match([record], to: [helper, window])

        XCTAssertEqual(matches[0]?.live.id, 21)
        XCTAssertEqual(matches[0]?.basis, .position)
    }

    func testEmptyTitlesDoNotOutrankNamedWindowAtSavedFrame() {
        let matches = WindowMatcher.match(
            [saved(1, "Thaw", "", x: 1000)],
            to: [live(20, "Thaw", "", x: 0), live(21, "Thaw", "General", x: 1000)]
        )

        XCTAssertEqual(matches[0]?.live.id, 21)
        XCTAssertEqual(matches[0]?.basis, .position)
    }

    func testWindowIdentityStillWinsWithMissingTitles() {
        let matches = WindowMatcher.match(
            [saved(7, "Notes", "", pid: 42)],
            to: [live(8, "Notes", "", pid: 42), live(7, "Notes", "Renamed", pid: 42, x: 900)]
        )

        XCTAssertEqual(matches[0]?.live.id, 7)
        XCTAssertEqual(matches[0]?.basis, .sameWindow)
    }

    func testNeverPairsDifferentApps() {
        let matches = WindowMatcher.match(
            [saved(1, "Mail", "Inbox", bundle: "com.apple.mail")],
            to: [live(2, "Mail", "Inbox", bundle: "com.other.mail"), live(3, "Notes", "Inbox")]
        )
        XCTAssertNil(matches[0])
    }

    func testEachLiveWindowIsUsedOnce() {
        let matches = WindowMatcher.match(
            [saved(1, "Notes", "A"), saved(2, "Notes", "A")],
            to: [live(10, "Notes", "A")]
        )
        XCTAssertEqual(matches.count, 1)
    }
}

final class SnapshotBuilderTests: XCTestCase {
    func testBuildsDisplaysSpacesAndWindows() {
        let display = LiveDisplay(id: 1, uuid: "D", frame: Rect(x: 0, y: 0, w: 1920, h: 1080), isMain: true)
        let spaces = [
            LiveSpace(id: 1, key: "desk", kind: .desktop, displayUUID: "D", index: 0, isActive: false),
            LiveSpace(id: 2, key: "sys", kind: .other("type2"), displayUUID: "D", index: 1, isActive: false),
            LiveSpace(id: 3, key: "split", kind: .splitView, displayUUID: "D", index: 2, isActive: true,
                      tiles: [LiveTile(windowID: 31, appName: "B", title: nil, side: .right)]),
        ]
        let windows = [
            LiveWindow(id: 10, pid: 1, appName: "A", title: "a", frame: Rect(x: 0, y: 0, w: 500, h: 500),
                       isOnscreen: false, spaceID: 1),
            LiveWindow(id: 30, pid: 2, appName: "C", title: "c", frame: Rect(x: 0, y: 0, w: 960, h: 1080),
                       isOnscreen: true, spaceID: 3),
            LiveWindow(id: 31, pid: 3, appName: "B", title: "b", frame: Rect(x: 960, y: 0, w: 960, h: 1080),
                       isOnscreen: true, spaceID: 3),
            // not on any space and not minimized: a hidden helper window
            LiveWindow(id: 40, pid: 4, appName: "H", title: "", frame: Rect(x: 0, y: 0, w: 500, h: 500),
                       isOnscreen: false, spaceID: nil),
            LiveWindow(id: 41, pid: 4, appName: "H", title: "min", frame: Rect(x: 0, y: 0, w: 500, h: 500),
                       isOnscreen: false, spaceID: nil, isMinimized: true),
        ]
        let snapshot = SnapshotBuilder.build(
            from: LiveState(displays: [display], spaces: spaces, windows: windows), created: "now"
        )

        XCTAssertEqual(snapshot.displays.first?.spaceUUIDs, ["desk", "split"])
        XCTAssertEqual(snapshot.displays.first?.activeSpaceUUID, "split")
        XCTAssertEqual(snapshot.spaces.map(\.uuid), ["desk", "split"])
        XCTAssertEqual(snapshot.windows.map(\.windowID), [10, 30, 31, 41])
        XCTAssertEqual(snapshot.windows[0].spaceUUID, "desk")
        XCTAssertEqual(snapshot.windows[2].splitSide, .right, "from tile metadata")
        XCTAssertEqual(snapshot.windows[1].splitSide, .left, "the side the tiles left free")
        XCTAssertEqual(snapshot.windows[3].isMinimized, true)
        XCTAssertEqual(snapshot.windows[3].displayUUID, "D", "display from the frame")
        XCTAssertNil(snapshot.windows[0].splitSide)
    }
}

final class SnapshotStoreTests: XCTestCase {
    func testSaveListLoad() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rememoru-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SnapshotStore(directory: dir)
        XCTAssertNil(store.latest)

        let snapshot = Snapshot(created: "c", displays: [], spaces: [], windows: [])
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try store.save(snapshot, date: date)
        let second = try store.save(snapshot, date: date)
        XCTAssertNotEqual(first, second, "same second gets a suffix, not an overwrite")
        XCTAssertEqual(store.list().count, 2)
        XCTAssertEqual(try store.load(first), snapshot)
    }

    func testLatestIsByCaptureTimeNotFileTime() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rememoru-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SnapshotStore(directory: dir)
        let snapshot = Snapshot(created: "c", displays: [], spaces: [], windows: [])
        let saved = try store.save(snapshot, date: Date(timeIntervalSince1970: 1_800_000_000))
        // an old Python snapshot copied in afterwards has the newest mtime
        let copied = dir.appendingPathComponent("rememoru-20200101-080000.json")
        try snapshot.encoded().write(to: copied)

        // compare names: on macOS the temp dir is /var/..., listings say /private/var/...
        XCTAssertEqual(store.latest?.url.lastPathComponent, saved.lastPathComponent)
        XCTAssertEqual(store.list().map(\.url.lastPathComponent), [saved.lastPathComponent, copied.lastPathComponent])
    }
}
