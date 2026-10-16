#if os(macOS)
import XCTest
@testable import RememoruMac

final class WindowCommandFocusTests: XCTestCase {
    private final class FocusState {
        var requests = 0
        var reads = 0
        var active = true
        var readyAfterRequest = 2
        var cancelOnRead: Int?
        var cancelOnRequest = false
        var cancelOnWait = false
        var recoverDuringWait = false

        func acquire() -> Bool {
            WindowCommandFocus.acquire(
                canContinue: { self.active },
                requestFocus: {
                    self.requests += 1
                    if self.cancelOnRequest { self.active = false }
                },
                isReady: {
                    self.reads += 1
                    if self.cancelOnRead == self.reads { self.active = false }
                    return self.requests >= self.readyAfterRequest
                },
                waitUntilReady: { condition in
                    if self.cancelOnWait { self.active = false }
                    if self.recoverDuringWait { self.readyAfterRequest = self.requests }
                    return condition() == true
                }
            )
        }
    }

    func testDroppedFirstRequestRecoversOnSecondRequest() {
        let state = FocusState()
        XCTAssertTrue(state.acquire())
        XCTAssertEqual(state.requests, 2)
    }

    func testPermanentWrongWindowStopsAfterThreeRequests() {
        let state = FocusState()
        state.readyAfterRequest = .max
        XCTAssertFalse(state.acquire())
        XCTAssertEqual(state.requests, 3)
    }

    func testAlreadyReadyDoesNotRequestFocus() {
        let state = FocusState()
        state.readyAfterRequest = 0
        XCTAssertTrue(state.acquire())
        XCTAssertEqual(state.requests, 0)
    }

    func testCancellationDuringReadPreventsFocusAndSuccess() {
        let state = FocusState()
        state.readyAfterRequest = 0
        state.cancelOnRead = 1
        XCTAssertFalse(state.acquire())
        XCTAssertEqual(state.requests, 0)
    }

    func testCancellationDuringRequestPreventsLaterReadsAndRequests() {
        let state = FocusState()
        state.cancelOnRequest = true
        XCTAssertFalse(state.acquire())
        XCTAssertEqual(state.requests, 1)
        XCTAssertEqual(state.reads, 1)
    }

    func testCancellationDuringPollRejectsReadinessAndStopsRequests() {
        let state = FocusState()
        state.readyAfterRequest = 1
        state.cancelOnRead = 2
        XCTAssertFalse(state.acquire())
        XCTAssertEqual(state.requests, 1)
        XCTAssertEqual(state.reads, 2)
    }

    func testAlreadyCancelledDoesNotReadOrRequestFocus() {
        let state = FocusState()
        state.active = false
        XCTAssertFalse(state.acquire())
        XCTAssertEqual(state.requests, 0)
        XCTAssertEqual(state.reads, 0)
    }

    func testCancellationDuringWaitPreventsLaterRequests() {
        let state = FocusState()
        state.cancelOnWait = true
        XCTAssertFalse(state.acquire())
        XCTAssertEqual(state.requests, 1)
    }

    func testReadinessCanRecoverDuringPollingWithoutAnotherRequest() {
        let state = FocusState()
        state.recoverDuringWait = true
        XCTAssertTrue(state.acquire())
        XCTAssertEqual(state.requests, 1)
    }
}
#endif
