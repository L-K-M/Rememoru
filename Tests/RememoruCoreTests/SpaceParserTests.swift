import XCTest
@testable import RememoruCore

final class SpaceParserTests: XCTestCase {
    /// Condensed from a real macOS 26.7 `SLSCopyManagedDisplaySpaces` dump.
    private func macOS26Displays() throws -> [[String: Any]] {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "macos26-managed-display-spaces", withExtension: "json", subdirectory: "Fixtures"
        ))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [[String: Any]])
    }

    func testMacOS26SplitViewAndFullscreenDetection() throws {
        let parsed = SpaceParser.parse(try macOS26Displays())
        let byID = Dictionary(uniqueKeysWithValues: parsed.spaces.map { ($0.id, $0) })

        XCTAssertEqual(byID[39]?.kind, .desktop)
        XCTAssertEqual(byID[65]?.kind, .fullscreen, "one tile is a solo fullscreen window")
        XCTAssertEqual(byID[409]?.kind, .splitView, "two tiles are a Split View pair")
        XCTAssertEqual(byID[409]?.isActive, true)
        XCTAssertEqual(byID[39]?.isActive, false)
        XCTAssertEqual(parsed.spaces.map(\.index), [0, 1, 2])
        XCTAssertEqual(parsed.spaces.map(\.displayUUID), ["d26", "d26", "d26"])

        let tiles = try XCTUnwrap(byID[409]?.tiles)
        XCTAssertEqual(tiles.map(\.appName), ["WhatsApp", "WeChat"])
        XCTAssertEqual(tiles.map(\.side), [.left, .right])
        XCTAssertEqual(tiles.map(\.windowID), [599, 2398])
    }

    func testTileSubSpacesTranslateToOuterSpace() throws {
        let parsed = SpaceParser.parse(try macOS26Displays())
        XCTAssertEqual(parsed.tileParents[67], 65)
        XCTAssertEqual(parsed.tileParents[411], 409)
        XCTAssertEqual(parsed.tileParents[425], 409)
        XCTAssertEqual(parsed.tileWindowSpaces[569], 65)
        XCTAssertEqual(parsed.tileWindowSpaces[599], 409)
        XCTAssertEqual(parsed.tileWindowSpaces[2398], 409)

        // a tiled window reporting only its sub-space
        XCTAssertEqual(parsed.resolveSpace(windowID: 1, reported: [425]), 409)
        // tile id and outer id together collapse to one space
        XCTAssertEqual(parsed.resolveSpace(windowID: 1, reported: [411, 409]), 409)
        // the tile window table wins over whatever the query said
        XCTAssertEqual(parsed.resolveSpace(windowID: 569, reported: [39]), 65)
    }

    func testWindowsOnNoOrSeveralSpacesResolveToNil() throws {
        let parsed = SpaceParser.parse(try macOS26Displays())
        XCTAssertNil(parsed.resolveSpace(windowID: 1, reported: []), "minimized or hidden")
        XCTAssertNil(parsed.resolveSpace(windowID: 1, reported: [39, 65]), "shown on all desktops")
        XCTAssertNil(parsed.resolveSpace(windowID: 1, reported: [9999]), "unknown space")
        XCTAssertEqual(parsed.resolveSpace(windowID: 1, reported: [39]), 39)
    }

    func testEmptyAndDuplicateUUIDsGetUniqueKeys() {
        let displays: [[String: Any]] = [
            ["Display Identifier": "A",
             "Current Space": ["ManagedSpaceID": 1],
             "Spaces": [["ManagedSpaceID": 1, "uuid": "", "type": 0],
                        ["ManagedSpaceID": 2, "uuid": "same", "type": 0]]],
            ["Display Identifier": "B",
             "Spaces": [["ManagedSpaceID": 3, "uuid": "same", "type": 0],
                        ["ManagedSpaceID": 4, "type": 2]]],
        ]
        let parsed = SpaceParser.parse(displays)
        XCTAssertEqual(parsed.spaces.map(\.key), ["id:1", "same", "id:3", "id:4"])
        XCTAssertEqual(parsed.spaces.last?.kind, .other("type2"))
    }

    func testMissingTypeFallsBackToQuery() {
        let displays: [[String: Any]] = [
            ["Display Identifier": "A",
             "Spaces": [["ManagedSpaceID": 7, "uuid": "u7"]]],
        ]
        let parsed = SpaceParser.parse(displays) { id in id == 7 ? 4 : nil }
        XCTAssertEqual(parsed.spaces.first?.kind, .fullscreen)
    }
}
