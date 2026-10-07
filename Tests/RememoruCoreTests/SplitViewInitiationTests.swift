import XCTest
@testable import RememoruCore

final class SplitViewInitiationTests: XCTestCase {
    func testWeChatOnRightInitiatesFromItsOwnWindow() {
        XCTAssertEqual(SplitViewInitiation.preferredSide(
            leftBundleID: "net.whatsapp.WhatsApp", rightBundleID: WeChatStartup.bundleID
        ), .right)
    }

    func testWeChatOnLeftInitiatesFromItsOwnWindow() {
        XCTAssertEqual(SplitViewInitiation.preferredSide(
            leftBundleID: WeChatStartup.bundleID, rightBundleID: "net.whatsapp.WhatsApp"
        ), .left)
    }

    func testOtherPairsKeepTheOriginalLeftEntry() {
        XCTAssertEqual(SplitViewInitiation.preferredSide(
            leftBundleID: "com.apple.TextEdit", rightBundleID: "com.apple.Terminal"
        ), .left)
    }

    func testUnknownAppsKeepTheOriginalLeftEntry() {
        XCTAssertEqual(SplitViewInitiation.preferredSide(leftBundleID: nil, rightBundleID: nil), .left)
    }

    func testWeChatBundleMustMatchExactly() {
        XCTAssertEqual(SplitViewInitiation.preferredSide(
            leftBundleID: nil, rightBundleID: WeChatStartup.bundleID + ".other"
        ), .left)
    }

    func testTwoWeChatWindowsKeepTheOriginalLeftEntry() {
        XCTAssertEqual(SplitViewInitiation.preferredSide(
            leftBundleID: WeChatStartup.bundleID, rightBundleID: WeChatStartup.bundleID
        ), .left)
    }
}
