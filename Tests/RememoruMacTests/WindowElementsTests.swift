#if os(macOS)
import XCTest
@testable import RememoruMac

final class WindowElementsTests: XCTestCase {
    func testPartialProbeResumesForEitherMode() {
        for mode in [WindowElements.ProbeMode.oncePerInvalidation, .repeatCompletedScans] {
            XCTAssertEqual(WindowElements.probeStart(after: 0, mode: mode), 0)
            XCTAssertEqual(WindowElements.probeStart(after: WindowElements.maxElementID - 1, mode: mode),
                           WindowElements.maxElementID - 1)
        }
    }

    func testCompletedProbeStopsUntilInvalidationByDefault() {
        for cursor in [WindowElements.maxElementID, WindowElements.maxElementID + 1] {
            XCTAssertNil(WindowElements.probeStart(after: cursor, mode: .oncePerInvalidation))
        }
    }

    func testCompletedProbeWrapsWhenRepetitionIsRequested() {
        for cursor in [WindowElements.maxElementID, WindowElements.maxElementID + 1] {
            XCTAssertEqual(WindowElements.probeStart(after: cursor, mode: .repeatCompletedScans), 0)
        }
    }

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
