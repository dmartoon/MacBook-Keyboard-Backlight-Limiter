import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService — Apple's supported mechanism since
/// macOS 13, replacing the deprecated LaunchAgent-plist approach.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns nil on success, or a human-readable reason on failure.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled { return nil }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return (error as NSError).localizedDescription
        }
    }

    /// SMAppService registers the bundle at its current path, so running from a
    /// temporary or Downloads location produces a login item that breaks when
    /// the app is moved.
    static var isInApplications: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }
}
