/// Chooses which saved window opens the system Split View picker.
public enum SplitViewInitiation {
    public static func preferredSide(leftBundleID: String?, rightBundleID: String?) -> SplitSide {
        // WeChat's picker hits can describe source content outside the
        // selectable thumbnail. Use its own menu without changing its
        // saved side; other pairs retain the original left-window entry.
        if rightBundleID == WeChatStartup.bundleID, leftBundleID != WeChatStartup.bundleID { return .right }
        return .left
    }
}
