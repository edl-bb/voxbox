import ServiceManagement

/// Open-at-login via the system login-item list. That list is the source of
/// truth — not UserDefaults — so the Settings toggle stays correct if the
/// user turns VoxBox off in System Settings.
enum LoginItemService {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
