import XCTest
@testable import RememoruCore

final class CommandLineTests: XCTestCase {
    func testPlainAppLaunchIsNotACommand() throws {
        XCTAssertNil(try CLIParser.parse([]))
        XCTAssertNil(try CLIParser.parse(["-psn_0_1234"]))
        XCTAssertNil(try CLIParser.parse(["-NSDocumentRevisionsDebugMode", "YES"]))
    }

    func testRestoreOptions() throws {
        var expected = RestoreOptions()
        expected.fullscreen = false
        expected.splitView = false
        expected.arrangeSpaces = false
        expected.launchApps = true
        expected.displayFallback = .mainDisplay
        XCTAssertEqual(
            try CLIParser.parse(["restore", "a.json", "--dry-run", "--no-fullscreen", "--no-split",
                                 "--no-arrange", "--launch", "--fallback-main-display"]),
            .restore(path: "a.json", mode: .dryRun, options: expected)
        )
        XCTAssertEqual(try CLIParser.parse(["restore"]),
                       .restore(path: nil, mode: .apply, options: RestoreOptions()))
    }

    func testSnapshotOutput() throws {
        XCTAssertEqual(try CLIParser.parse(["snapshot", "-o", "x.json"]), .snapshot(output: "x.json"))
        XCTAssertEqual(try CLIParser.parse(["snapshot"]), .snapshot(output: nil))
        XCTAssertThrowsError(try CLIParser.parse(["snapshot", "-o"]))
    }

    func testRejectsUnknownOptionsAndExtraArguments() {
        XCTAssertThrowsError(try CLIParser.parse(["restore", "--bogus"]))
        XCTAssertThrowsError(try CLIParser.parse(["restore", "a.json", "b.json"]))
        XCTAssertThrowsError(try CLIParser.parse(["doctor", "now"]))
    }

    func testReportSummary() {
        var report = RestoreReport()
        let ref = WindowTarget(LiveWindow(id: 1, pid: 1, appName: "A", title: "", frame: Rect(x: 0, y: 0, w: 1, h: 1),
                                       isOnscreen: true))
        report.entries = [.init(step: .exitFullscreen(ref), outcome: .done),
                          .init(step: .exitFullscreen(ref), outcome: .failed("no"))]
        XCTAssertEqual(report.summary, "1 of 2 step(s) done, 1 failed")
        XCTAssertFalse(report.isClean)
    }
}
