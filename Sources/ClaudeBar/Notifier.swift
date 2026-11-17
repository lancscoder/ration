import ClaudeBarCore
import Foundation
import os
import UserNotifications

/// Thin wrapper around UserNotifications. Fired-threshold keys persist in
/// UserDefaults so a relaunch doesn't repeat an alert for the same window.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated private static let log = Logger(subsystem: Log.subsystem, category: "notify")
    private let defaults: UserDefaults
    private let firedKey = "firedThresholdKeys"
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        center.delegate = self
    }

    var firedKeys: Set<String> {
        get { Set(defaults.stringArray(forKey: firedKey) ?? []) }
        set { defaults.set(Array(newValue).sorted().suffix(64), forKey: firedKey) }
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { Self.log.error("notification auth failed: \(error.localizedDescription, privacy: .public)") }
            Self.log.info("notification auth granted: \(granted)")
        }
    }

    func send(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { Self.log.error("notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func sendUsageAlert(_ alert: ThresholdAlert, now: Date) {
        var body = "\(alert.title) is at \(Fmt.percent(alert.utilization))."
        if let reset = alert.resetsAt, reset > now {
            body += " Resets in \(Fmt.duration(reset.timeIntervalSince(now))) (\(Fmt.resetClock(reset, now: now)))."
        }
        send(title: "Claude usage passed \(alert.threshold)%", body: body, id: "usage-\(alert.limitID)-\(alert.threshold)")
    }

    func sendWaiting(_ session: SessionInfo) {
        send(title: "Claude is waiting for you",
             body: "\(session.projectName)\(session.name.map { " · \($0)" } ?? "") finished its turn.",
             id: "waiting-\(session.sessionId)")
    }

    // Show banners even though the menu bar app counts as "active".
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
