import XCTest
@testable import RememoruCore

final class SnapshotTests: XCTestCase {
    func testDecodesSnapshotWrittenByPythonVersion() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "python-v1-snapshot", withExtension: "json", subdirectory: "Fixtures"
        ))
        let snapshot = try Snapshot.decode(Data(contentsOf: url))

        XCTAssertEqual(snapshot.displays.first?.spaceUUIDs, ["s1", "s2", "s3"])
        XCTAssertEqual(snapshot.displays.first?.activeSpaceUUID, "s2")
        XCTAssertEqual(snapshot.spaces.map(\.kind), [.desktop, .desktop, .fullscreen])
        XCTAssertEqual(snapshot.windows.first?.bundleID, "com.apple.Safari")
        XCTAssertEqual(snapshot.windows.first?.frame, Rect(x: 0, y: 0, w: 960, h: 1080))
        XCTAssertEqual(snapshot.windows.last?.title, "", "null title decodes as empty")
        XCTAssertNil(snapshot.windows.last?.bundleID)
    }

    func testRoundTripKeepsEverything() throws {
        let snapshot = Snapshot(
            created: "2026-09-25T10:00:00+0200",
            displays: [DisplayRecord(uuid: "D", frame: Rect(x: 0, y: 0, w: 100, h: 100),
                                     isMain: true, spaceUUIDs: ["a", "b"], activeSpaceUUID: "b")],
            spaces: [SpaceRecord(uuid: "a", id: 1, kind: .desktop, displayUUID: "D", index: 0, isActive: false),
                     SpaceRecord(uuid: "b", id: 2, kind: .splitView, displayUUID: "D", index: 1, isActive: true)],
            windows: [WindowRecord(windowID: 5, pid: 9, appName: "A", bundleID: nil, title: "t",
                                   frame: Rect(x: 1, y: 2, w: 3, h: 4), spaceUUID: "b", displayUUID: "D",
                                   splitSide: .right, isMinimized: true)]
        )
        let decoded = try Snapshot.decode(snapshot.encoded())
        XCTAssertEqual(decoded, snapshot)

        let json = try XCTUnwrap(String(data: snapshot.encoded(), encoding: .utf8))
        XCTAssertTrue(json.contains("\"type\" : \"tiled\""), "keeps the v1 space type names")
        XCTAssertTrue(json.contains("\"side\" : \"right\""))
    }

    func testUnknownSpaceTypeDecodesAsOther() throws {
        let json = #"{"uuid":"x","id":1,"type":"unknown(3)","display_uuid":"D","index":0,"active":false}"#
        let space = try JSONDecoder().decode(SpaceRecord.self, from: Data(json.utf8))
        XCTAssertEqual(space.kind, .other("unknown(3)"))
        XCTAssertFalse(space.kind.isRestorable)
    }

    func testRejectsOtherVersions() {
        let json = #"{"version":2,"created":"","displays":[],"spaces":[],"windows":[]}"#
        XCTAssertThrowsError(try Snapshot.decode(Data(json.utf8))) { error in
            XCTAssertEqual(error as? SnapshotError, .unsupportedVersion(2))
        }
    }

    func testDesktopOrdinalSkipsFullscreenSpaces() {
        let snapshot = Snapshot(
            created: "",
            displays: [DisplayRecord(uuid: "D", frame: Rect(x: 0, y: 0, w: 1, h: 1), isMain: true,
                                     spaceUUIDs: ["d1", "f1", "d2"], activeSpaceUUID: nil)],
            spaces: [SpaceRecord(uuid: "d1", id: 1, kind: .desktop, displayUUID: "D", index: 0, isActive: true),
                     SpaceRecord(uuid: "f1", id: 2, kind: .fullscreen, displayUUID: "D", index: 1, isActive: false),
                     SpaceRecord(uuid: "d2", id: 3, kind: .desktop, displayUUID: "D", index: 2, isActive: false)],
            windows: []
        )
        XCTAssertEqual(snapshot.desktopOrdinal(ofSpace: "d1"), 0)
        XCTAssertEqual(snapshot.desktopOrdinal(ofSpace: "d2"), 1)
        XCTAssertNil(snapshot.desktopOrdinal(ofSpace: "f1"))
        XCTAssertEqual(snapshot.desktopCount(onDisplay: "D"), 2)
    }
}
