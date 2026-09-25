#if os(macOS)
import Foundation
import RememoruCore
import ServiceManagement

/// User preferences, stored in the app's defaults domain.
struct Preferences {
    private enum Key {
        static let restoreAtLogin = "restoreAtLogin"
        static let loginDelay = "loginDelaySeconds"
        static let onboardingShown = "onboardingShown"
        static let launchApps = "launchApps"
    }

    static let loginDelayChoices = [10, 30, 60, 120]
    private static let defaultLoginDelay = 30

    private let defaults = UserDefaults.standard

    var restoreAtLogin: Bool {
        get { defaults.bool(forKey: Key.restoreAtLogin) }
        nonmutating set { defaults.set(newValue, forKey: Key.restoreAtLogin) }
    }

    /// Seconds to wait after login so apps can reopen their windows first.
    var loginDelay: Int {
        get { defaults.object(forKey: Key.loginDelay) as? Int ?? Self.defaultLoginDelay }
        nonmutating set { defaults.set(newValue, forKey: Key.loginDelay) }
    }

    /// Open apps with saved windows that are not running. On by default,
    /// since at login most apps are still starting.
    var launchApps: Bool {
        get { defaults.object(forKey: Key.launchApps) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.launchApps) }
    }

    var restoreOptions: RestoreOptions {
        var options = RestoreOptions()
        options.launchApps = launchApps
        return options
    }

    var onboardingShown: Bool {
        get { defaults.bool(forKey: Key.onboardingShown) }
        nonmutating set { defaults.set(newValue, forKey: Key.onboardingShown) }
    }
}

/// Registering the app itself as a login item (macOS 13+).
enum LoginItem {
    enum Change {
        case enabled
        case needsApproval
        case disabled
        case failed(String)
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Login items are recorded by path; registering a copy in Downloads or
    /// a build folder would point the login item at that copy.
    static var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").path
        return path == "/Applications" || path == userApplications
    }

    static func setEnabled(_ enabled: Bool) -> Change {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                return SMAppService.mainApp.status == .requiresApproval ? .needsApproval : .enabled
            }
            try SMAppService.mainApp.unregister()
            return .disabled
        } catch {
            if enabled, SMAppService.mainApp.status == .requiresApproval { return .needsApproval }
            return .failed(error.localizedDescription)
        }
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
#endif
