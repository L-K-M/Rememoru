#if os(macOS)
import XCTest
@testable import RememoruMac

final class WindowElementsTests: XCTestCase {
    func testIncompleteMappingKeepsKnownWindowsWithoutProvingAbsence() {
        let listing = WindowElements.Listing(["first", "unreadable", "last"], windowID: { window in
            switch window {
            case "first": return 10
            case "last": return 20
            default: return nil
            }
        })

        XCTAssertEqual(listing.windows, [10: "first", 20: "last"])
        XCTAssertFalse(listing.isComplete)
    }

    func testSuccessfulEmptyListingCanProveAbsence() {
        let listing = WindowElements.Listing([String](), windowID: { _ in
            XCTFail("an empty list needs no ID lookup")
            return nil
        })

        XCTAssertEqual(listing.windows, [:])
        XCTAssertTrue(listing.isComplete)
    }
}
#endif
