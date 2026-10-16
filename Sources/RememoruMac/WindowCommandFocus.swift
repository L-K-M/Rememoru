#if os(macOS)
/// Repeats focus requests only until the exact command target is ready.
enum WindowCommandFocus {
    private static let maximumRequests = 3

    static func acquire(
        canContinue: @escaping () -> Bool,
        requestFocus: () -> Void,
        isReady: @escaping () -> Bool,
        waitUntilReady: (_ condition: () -> Bool?) -> Bool
    ) -> Bool {
        guard canContinue() else { return false }
        let ready = isReady()
        guard canContinue() else { return false }
        if ready { return true }
        for _ in 0..<maximumRequests {
            guard canContinue() else { return false }
            requestFocus()
            guard canContinue() else { return false }
            let confirmed = waitUntilReady {
                guard canContinue() else { return false }
                let ready = isReady()
                guard canContinue() else { return false }
                return ready ? true : nil
            }
            guard canContinue() else { return false }
            if confirmed { return true }
        }
        return false
    }
}
#endif
