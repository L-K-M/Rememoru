import XCTest
@testable import RememoruCore

final class WindowCommandReadinessTests: XCTestCase {
    func testRequestedWindowMustBeMainAndFocusedInForegroundApp() {
        XCTAssertTrue(WindowCommandReadiness.permits(
            targetWindowID: 4731, isFrontmost: true, mainWindowID: 4731, focusedWindowID: 4731
        ))
    }

    func testBackgroundAppIsNotReadyEvenWhenItsWindowIDsMatch() {
        XCTAssertFalse(WindowCommandReadiness.permits(
            targetWindowID: 4731, isFrontmost: false, mainWindowID: 4731, focusedWindowID: 4731
        ))
    }

    func testRetainedStartupWindowMustNotReceiveMainWindowCommand() {
        XCTAssertFalse(WindowCommandReadiness.permits(
            targetWindowID: 4731, isFrontmost: true, mainWindowID: 409, focusedWindowID: 409
        ))
    }

    func testFocusOnAnotherWindowIsNotReady() {
        XCTAssertFalse(WindowCommandReadiness.permits(
            targetWindowID: 4731, isFrontmost: true, mainWindowID: 4731, focusedWindowID: 409
        ))
    }

    func testUnknownReadinessIsNotAssumedSuccessful() {
        XCTAssertFalse(WindowCommandReadiness.permits(
            targetWindowID: 4731, isFrontmost: nil, mainWindowID: 4731, focusedWindowID: 4731
        ))
        XCTAssertFalse(WindowCommandReadiness.permits(
            targetWindowID: 4731, isFrontmost: true, mainWindowID: nil, focusedWindowID: 4731
        ))
        XCTAssertFalse(WindowCommandReadiness.permits(
            targetWindowID: 4731, isFrontmost: true, mainWindowID: 4731, focusedWindowID: nil
        ))
    }
}
