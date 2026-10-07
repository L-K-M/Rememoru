/// Checks that an app's window commands will target the requested window.
public enum WindowCommandReadiness {
    public static func permits(
        targetWindowID: UInt32,
        isFrontmost: Bool?,
        mainWindowID: UInt32?,
        focusedWindowID: UInt32?
    ) -> Bool {
        isFrontmost == true
            && mainWindowID == targetWindowID
            && focusedWindowID == targetWindowID
    }
}
