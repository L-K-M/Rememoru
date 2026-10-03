import XCTest
@testable import RememoruCore

final class WeChatStartupTests: XCTestCase {
    private func snapshot(bundleID: String?) -> Snapshot {
        Snapshot(created: "", displays: [], spaces: [], windows: [
            WindowRecord(windowID: 1, pid: 1, appName: "WeChat", bundleID: bundleID, title: "WeChat",
                         frame: Rect(x: 0, y: 0, w: 800, h: 600), spaceUUID: nil, displayUUID: nil),
        ])
    }

    func testPreparesSavedWeChatWhenOpeningAppsIsEnabled() {
        var options = RestoreOptions()
        options.launchApps = true

        XCTAssertTrue(WeChatStartup.shouldPrepare(
            snapshot: snapshot(bundleID: "com.tencent.xinWeChat"), options: options, mode: .apply
        ))
        XCTAssertFalse(WeChatStartup.shouldPrepare(
            snapshot: snapshot(bundleID: "com.other.WeChat"), options: options, mode: .apply
        ))
        XCTAssertFalse(WeChatStartup.shouldPrepare(
            snapshot: snapshot(bundleID: nil), options: options, mode: .apply
        ))
    }

    func testDoesNotPrepareDuringDryRunOrWhenOpeningAppsIsDisabled() {
        let saved = snapshot(bundleID: "com.tencent.xinWeChat")
        var options = RestoreOptions()
        XCTAssertFalse(WeChatStartup.shouldPrepare(snapshot: saved, options: options, mode: .apply))

        options.launchApps = true
        XCTAssertFalse(WeChatStartup.shouldPrepare(snapshot: saved, options: options, mode: .dryRun))
    }

    func testRecognizesOnlyTheExactOpenButton() {
        XCTAssertTrue(WeChatStartup.isOpenButton(isButton: true, labels: ["Open WeChat"]))
        XCTAssertTrue(WeChatStartup.isOpenButton(isButton: true, labels: ["", "Open WeChat"]))
        XCTAssertFalse(WeChatStartup.isOpenButton(isButton: false, labels: ["Open WeChat"]))
        for label in ["Switch Account", "Transfer files only", "Log In", "Confirm on Phone", "Open WeChat settings"] {
            XCTAssertFalse(WeChatStartup.isOpenButton(isButton: true, labels: [label]), label)
        }
    }

    func testStartupMinimizeControlDoesNotProveMainWindowReadiness() {
        XCTAssertFalse(WeChatStartup.isMainWindow(
            isStandardWindow: true, isFullscreen: false, hasMinimizeButton: true, isZoomEnabled: false
        ))
        XCTAssertTrue(WeChatStartup.isMainWindow(
            isStandardWindow: true, isFullscreen: false, hasMinimizeButton: true, isZoomEnabled: true
        ))
        XCTAssertTrue(WeChatStartup.isMainWindow(
            isStandardWindow: true, isFullscreen: true, hasMinimizeButton: false, isZoomEnabled: false
        ))
        XCTAssertFalse(WeChatStartup.isMainWindow(
            isStandardWindow: false, isFullscreen: true, hasMinimizeButton: true, isZoomEnabled: true
        ))
    }
}
