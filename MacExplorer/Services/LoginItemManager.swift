import Foundation
import ServiceManagement

/// Manages "Open at Login" using the modern SMAppService API (macOS 13+).
/// Registering adds the app to System Settings > General > Login Items.
enum LoginItemManager {

    /// Whether the app is currently registered to open at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Turn launch-at-login on or off. Returns true on success.
    /// Registration requires the app to be in /Applications and properly
    /// code-signed with a stable identity — an ad-hoc build may be refused
    /// by the system or silently fail to persist across reboots.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            NSLog("LoginItemManager: failed to set launch-at-login=\(enabled): \(error.localizedDescription)")
            return false
        }
    }
}
