import XCTest
@testable import RememoruCore

final class SpaceThumbnailSurveyTests: XCTestCase {

    // MARK: - Init validation

    func testInitRejectsEmpty() {
        XCTAssertNil(SpaceThumbnailSurvey(knownIDs: []))
    }

    func testInitRejectsDuplicates() {
        XCTAssertNil(SpaceThumbnailSurvey(knownIDs: [10, 20, 10]))
    }

    func testInitAcceptsSingle() throws {
        let survey = try XCTUnwrap(SpaceThumbnailSurvey(knownIDs: [42]))
        XCTAssertNil(survey.order)
        XCTAssertFalse(survey.failed)
    }

    func testInitAcceptsThree() throws {
        let survey = try XCTUnwrap(SpaceThumbnailSurvey(knownIDs: [10, 20, 30]))
        XCTAssertNil(survey.order)
        XCTAssertFalse(survey.failed)
    }

    // MARK: - Requested indices sequence

    func testRequestedIndicesForwardThenReversed() throws {
        var s = try XCTUnwrap(SpaceThumbnailSurvey(knownIDs: [10, 20, 30]))

        var collected: [Int?] = []
        // Interleave observe() so pending is cleared each cycle
        let observations: [UInt64] = [20, 30, 10, 10, 30, 20]
        for obs in observations {
            collected.append(s.nextIndex())
            _ = s.observe(activeID: obs)
        }
        // Exhausted; next should return nil
        collected.append(s.nextIndex())

        XCTAssertEqual(collected, [0, 1, 2, 2, 1, 0, nil])
    }

    // MARK: - Full happy path

    func testCompleteSurveyYieldsOrder() throws {
        let known: [UInt64] = [10, 20, 30]
        var s = try XCTUnwrap(SpaceThumbnailSurvey(knownIDs: known))

        // First pass (forward): indices 0,1,2
        XCTAssertEqual(s.nextIndex(), 0)
        XCTAssertTrue(s.observe(activeID: 20))
        XCTAssertEqual(s.nextIndex(), 1)
        XCTAssertTrue(s.observe(activeID: 30))
        XCTAssertEqual(s.nextIndex(), 2)
        XCTAssertTrue(s.observe(activeID: 10))

        // Order not set yet; first pass alone is insufficient
        XCTAssertNil(s.order)

        // Second pass (reversed): indices 2,1,0
        XCTAssertEqual(s.nextIndex(), 2)
        XCTAssertTrue(s.observe(activeID: 10))
        XCTAssertEqual(s.nextIndex(), 1)
        XCTAssertTrue(s.observe(activeID: 30))
        XCTAssertEqual(s.nextIndex(), 0)
        XCTAssertTrue(s.observe(activeID: 20))

        let order = try XCTUnwrap(s.order)
        XCTAssertEqual(order, [20, 30, 10])
        XCTAssertFalse(s.failed)
    }

    // MARK: - Order not set after first three observations

    func testOrderNilAfterFirstPass() throws {
        var s = try XCTUnwrap(SpaceThumbnailSurvey(knownIDs: [10, 20, 30]))

        XCTAssertEqual(s.nextIndex(), 0)
        XCTAssertTrue(s.observe(activeID: 20))
        XCTAssertEqual(s.nextIndex(), 1)
        XCTAssertTrue(s.observe(activeID: 30))
        XCTAssertEqual(s.nextIndex(), 2)
        XCTAssertTrue(s.observe(activeID: 10))

        XCTAssertNil(s.order)
        XCTAssertFalse(s.failed)
    }

    // MARK: - Counterexample: delayed shifted first mapping must fail

    func testDelayedShiftedFirstMappingFails() throws {
        // First pass observes [30,10,20] for indices [0,1,2] → selected=[30,10,20]
        // Second pass index 2 expects selected[2]==20, but we observe 30 → mismatch
        var s = try XCTUnwrap(SpaceThumbnailSurvey(knownIDs: [10, 20, 30]))

        XCTAssertEqual(s.nextIndex(), 0)
        XCTAssertTrue(s.observe(activeID: 30))
        XCTAssertEqual(s.nextIndex(), 1)
        XCTAssertTrue(s.observe(activeID: 10))
        XCTAssertEqual(s.nextIndex(), 2)
        XCTAssertTrue(s.observe(activeID: 20))

        // Second pass: index 2 expects selected[2] (20), but observe 30
        XCTAssertEqual(s.nextIndex(), 2)
        XCTAssertFalse(s.observe(activeID: 30))

        XCTAssertTrue(s.failed)
        XCTAssertNil(s.order)
    }

    // MARK: - Duplicate first-pass IDs rejected

    func testDuplicateFirstPassIDFails() throws {
        var s = try XCTUnwrap(SpaceThumbnailSurvey(knownIDs: [10, 20, 30]))

        XCTAssertEqual(s.nextIndex(), 0)
        XCTAssertTrue(s.observe(activeID: 20))
        XCTAssertEqual(s.nextIndex(), 1)
        // Duplicate of 20 in first pass
        XCTAssertFalse(s.observe(activeID: 20))

        XCTAssertTrue(s.failed)
        XCTAssertNil(s.order)
    }

    // MARK: - Unknown ID rejected

    func testUnknownIDFails() throws {
        var s = try XCTUnwrap(SpaceThumbnailSurvey(knownIDs: [10, 20, 30]))

        XCTAssertEqual(s.nextIndex(), 0)
        XCTAssertFalse(s.observe(activeID: 99))

        XCTAssertTrue(s.failed)
        XCTAssertNil(s.order)
    }

    // MARK: - Nil ID rejected

    func testNilIDFails() throws {
        var s = try XCTUnwrap(SpaceThumbnailSurvey(knownIDs: [10, 20, 30]))

        XCTAssertEqual(s.nextIndex(), 0)
        XCTAssertFalse(s.observe(activeID: nil))

        XCTAssertTrue(s.failed)
        XCTAssertNil(s.order)
    }

    // MARK: - Observe before request fails

    func testObserveBeforeRequestFails() throws {
        var s = try XCTUnwrap(SpaceThumbnailSurvey(knownIDs: [10, 20, 30]))

        // Call observe without calling nextIndex first
        XCTAssertFalse(s.observe(activeID: 20))

        XCTAssertTrue(s.failed)
        XCTAssertNil(s.order)
    }

    // MARK: - Double nextIndex without observe fails

    func testDoubleNextIndexWithoutObserveFails() throws {
        var s = try XCTUnwrap(SpaceThumbnailSurvey(knownIDs: [10, 20, 30]))

        XCTAssertEqual(s.nextIndex(), 0)
        // Second nextIndex before observe; pending is still set
        XCTAssertNil(s.nextIndex())

        XCTAssertTrue(s.failed)
        XCTAssertNil(s.order)
    }

    // MARK: - No further requests after failure

    func testNoFurtherRequestsAfterFailure() throws {
        var s = try XCTUnwrap(SpaceThumbnailSurvey(knownIDs: [10, 20, 30]))

        XCTAssertEqual(s.nextIndex(), 0)
        XCTAssertFalse(s.observe(activeID: 99))
        XCTAssertTrue(s.failed)

        // nextIndex must return nil after failure
        XCTAssertNil(s.nextIndex())
    }

    func testNoFurtherObservesAfterFailure() throws {
        var s = try XCTUnwrap(SpaceThumbnailSurvey(knownIDs: [10, 20, 30]))

        XCTAssertEqual(s.nextIndex(), 0)
        XCTAssertFalse(s.observe(activeID: 99))
        XCTAssertTrue(s.failed)

        // Further observes return false (order is nil)
        XCTAssertFalse(s.observe(activeID: 20))
    }

    // MARK: - Single knownID still needs two matching selections

    func testSingleKnownIDNeedsTwoSelections() throws {
        var s = try XCTUnwrap(SpaceThumbnailSurvey(knownIDs: [42]))
        // indices = [0, 0] (forward [0] + reversed [0])

        // First pass: index 0
        XCTAssertEqual(s.nextIndex(), 0)
        XCTAssertTrue(s.observe(activeID: 42))

        // Not complete yet; needs second pass
        XCTAssertNil(s.order)

        // Second pass: index 0
        XCTAssertEqual(s.nextIndex(), 0)
        XCTAssertTrue(s.observe(activeID: 42))

        let order = try XCTUnwrap(s.order)
        XCTAssertEqual(order, [42])
        XCTAssertFalse(s.failed)
    }

    func testSingleKnownIDMismatchFails() throws {
        var s = try XCTUnwrap(SpaceThumbnailSurvey(knownIDs: [42]))

        XCTAssertEqual(s.nextIndex(), 0)
        XCTAssertTrue(s.observe(activeID: 42))

        // Second pass expects 42, but nothing else is known; any other ID fails
        XCTAssertEqual(s.nextIndex(), 0)
        // Only 42 is known; observe nil fails
        XCTAssertFalse(s.observe(activeID: nil))
        XCTAssertTrue(s.failed)
    }

    // MARK: - Completion stable on extra observation

    func testCompletionStableOnExtraObservation() throws {
        var s = try XCTUnwrap(SpaceThumbnailSurvey(knownIDs: [10, 20, 30]))

        // Complete the full survey
        XCTAssertEqual(s.nextIndex(), 0)
        XCTAssertTrue(s.observe(activeID: 20))
        XCTAssertEqual(s.nextIndex(), 1)
        XCTAssertTrue(s.observe(activeID: 30))
        XCTAssertEqual(s.nextIndex(), 2)
        XCTAssertTrue(s.observe(activeID: 10))
        XCTAssertEqual(s.nextIndex(), 2)
        XCTAssertTrue(s.observe(activeID: 10))
        XCTAssertEqual(s.nextIndex(), 1)
        XCTAssertTrue(s.observe(activeID: 30))
        XCTAssertEqual(s.nextIndex(), 0)
        XCTAssertTrue(s.observe(activeID: 20))

        let expectedOrder: [UInt64] = [20, 30, 10]
        XCTAssertEqual(s.order, expectedOrder)

        // Extra observations should not change order
        XCTAssertTrue(s.observe(activeID: 999))
        XCTAssertEqual(s.order, expectedOrder)
    }

    // MARK: - nextIndex returns nil after completion

    func testNextIndexNilAfterCompletion() throws {
        var s = try XCTUnwrap(SpaceThumbnailSurvey(knownIDs: [10, 20, 30]))

        // Complete the survey
        XCTAssertEqual(s.nextIndex(), 0)
        XCTAssertTrue(s.observe(activeID: 20))
        XCTAssertEqual(s.nextIndex(), 1)
        XCTAssertTrue(s.observe(activeID: 30))
        XCTAssertEqual(s.nextIndex(), 2)
        XCTAssertTrue(s.observe(activeID: 10))
        XCTAssertEqual(s.nextIndex(), 2)
        XCTAssertTrue(s.observe(activeID: 10))
        XCTAssertEqual(s.nextIndex(), 1)
        XCTAssertTrue(s.observe(activeID: 30))
        XCTAssertEqual(s.nextIndex(), 0)
        XCTAssertTrue(s.observe(activeID: 20))

        // No more indices after completion
        XCTAssertNil(s.nextIndex())
    }

    // MARK: - Second pass mismatch fails

    func testSecondPassMismatchFails() throws {
        var s = try XCTUnwrap(SpaceThumbnailSurvey(knownIDs: [10, 20, 30]))

        // First pass: selected = [20, 30, 10]
        XCTAssertEqual(s.nextIndex(), 0)
        XCTAssertTrue(s.observe(activeID: 20))
        XCTAssertEqual(s.nextIndex(), 1)
        XCTAssertTrue(s.observe(activeID: 30))
        XCTAssertEqual(s.nextIndex(), 2)
        XCTAssertTrue(s.observe(activeID: 10))

        // Second pass index 2 expects selected[2] == 10, but observe 20
        XCTAssertEqual(s.nextIndex(), 2)
        XCTAssertFalse(s.observe(activeID: 20))

        XCTAssertTrue(s.failed)
        XCTAssertNil(s.order)
    }

    // MARK: - Exhausted indices without completion fails

    func testExhaustedIndicesFails() throws {
        var s = try XCTUnwrap(SpaceThumbnailSurvey(knownIDs: [10, 20, 30]))

        // A second request while a selection is still pending must fail.
        XCTAssertEqual(s.nextIndex(), 0)
        XCTAssertNil(s.nextIndex()) // pending set, fails
        XCTAssertTrue(s.failed)
    }

    // MARK: - Two-element survey

    func testTwoElementSurvey() throws {
        var s = try XCTUnwrap(SpaceThumbnailSurvey(knownIDs: [100, 200]))
        // indices = [0, 1, 1, 0]

        XCTAssertEqual(s.nextIndex(), 0)
        XCTAssertTrue(s.observe(activeID: 100))
        XCTAssertEqual(s.nextIndex(), 1)
        XCTAssertTrue(s.observe(activeID: 200))
        XCTAssertNil(s.order)

        XCTAssertEqual(s.nextIndex(), 1)
        XCTAssertTrue(s.observe(activeID: 200))
        XCTAssertEqual(s.nextIndex(), 0)
        XCTAssertTrue(s.observe(activeID: 100))

        XCTAssertEqual(s.order, [100, 200])
        XCTAssertFalse(s.failed)
    }
    func testDuplicateReadingCanBeRetriedBeforeObservation() throws {
        var survey = try XCTUnwrap(SpaceThumbnailSurvey(knownIDs: [10, 20]))
        XCTAssertEqual(survey.nextIndex(), 0)
        XCTAssertTrue(survey.observe(activeID: 20))
        XCTAssertEqual(survey.nextIndex(), 1)
        XCTAssertFalse(survey.accepts(activeID: 20))
        XCTAssertFalse(survey.failed)
        XCTAssertTrue(survey.accepts(activeID: 10))
        XCTAssertTrue(survey.observe(activeID: 10))
        XCTAssertEqual(survey.nextIndex(), 1)
        XCTAssertTrue(survey.observe(activeID: 10))
        XCTAssertEqual(survey.nextIndex(), 0)
        XCTAssertFalse(survey.accepts(activeID: 10))
        XCTAssertTrue(survey.accepts(activeID: 20))
        XCTAssertTrue(survey.observe(activeID: 20))
        XCTAssertEqual(survey.order, [20, 10])
    }

}
