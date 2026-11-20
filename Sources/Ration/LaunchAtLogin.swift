import RationCore
import Foundation
import os
import ServiceManagement

/// Launch at login via `SMAppService.mainApp` (macOS 13+). Works best from a
/// stable location such as ~/Applications (`make install`).
enum LaunchAtLogin {
    private static let log = Logger(subsystem: Log.subsystem, category: "login")

    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            if status != .enabled { try SMAppService.mainApp.register() }
        } else {
            if status == .enabled || status == .requiresApproval { try SMAppService.mainApp.unregister() }
        }
        log.info("launch at login now \(String(describing: status.rawValue))")
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
