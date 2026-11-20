import RationCore
import Foundation
import os
import UserNotifications

/// Thin wrapper around UserNotifications. Fired-threshold keys persist in
/// UserDefaults so a relaunch doesn't repeat an alert for the same window.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated private static let log = Logger(subsystem: Log.subsystem, category: "notify")
    private let defaults: UserDefaults
    private let firedStore: FiredThresholdStore
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.firedStore = FiredThresholdStore(defaults: defaults)
        super.init()
        center.delegate = self
    }

    var firedKeys: Set<String> {
        get { firedStore.keys }
        set { firedStore.keys = newValue }
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

    /// Schedules (or reschedules, same id) a notification at the limit's reset time.
    func scheduleResetReminder(_ limit: LimitDisplay) {
        guard let reset = limit.resetsAt else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(limit.title) limit has reset"
        content.body = "You'd used \(Fmt.percent(limit.utilization)). It's back to 0%."
        content.sound = .default
        // A few seconds after the reset so a refresh right away already shows it.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, reset.timeIntervalSinceNow + 5), repeats: false)
        center.add(UNNotificationRequest(identifier: "reset-\(limit.id)", content: content, trigger: trigger)) { error in
            if let error { Self.log.error("reset reminder failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func cancelResetReminders() {
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix("reset-") }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    func sendWaiting(_ session: SessionInfo) {
        let where_ = "\(session.projectName)\(session.name.map { " · \($0)" } ?? "")"
        if session.needsPermission {
            send(title: "Claude needs your permission", body: "\(where_) is waiting for you to approve a step.",
                 id: "waiting-\(session.sessionId)")
        } else {
            send(title: "Claude is waiting for you", body: "\(where_) finished its turn.", id: "waiting-\(session.sessionId)")
        }
    }

    // Show banners even though the menu bar app counts as "active".
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
