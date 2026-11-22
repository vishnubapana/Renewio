import Foundation
import UserNotifications

/// Schedules local macOS notifications for installs approaching / past the 7-day signing window.
enum ExpiryNotifier {
    private static let soonPrefix = "renuvio.expiry.soon."
    private static let expiredPrefix = "renuvio.expiry.expired."
    /// Match the UI "Renew soon" threshold.
    static let renewSoonLeadTime: TimeInterval = 48 * 60 * 60

    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func reschedule(for config: ReNuvioConfig?) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let ours = pending
                .map(\.identifier)
                .filter { $0.hasPrefix(soonPrefix) || $0.hasPrefix(expiredPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ours)

            guard let config else { return }
            let now = Date()

            for install in config.installs {
                guard let expiresAt = install.expiresAt else { continue }
                let deviceName = config.devices.first(where: { $0.id == install.deviceID })?.name ?? "device"
                let soonAt = expiresAt.addingTimeInterval(-renewSoonLeadTime)

                if soonAt > now {
                    schedule(
                        id: soonPrefix + install.id.uuidString,
                        title: "\(install.name) expires soon",
                        body: "Refresh within 48 hours to keep it signed on \(deviceName).",
                        at: soonAt
                    )
                }

                if expiresAt > now {
                    schedule(
                        id: expiredPrefix + install.id.uuidString,
                        title: "\(install.name) expired",
                        body: "Signing lapsed on \(deviceName). Open ReNuvio and renew.",
                        at: expiresAt
                    )
                }
            }
        }

        // If already in the warning window while the app is open, nudge once per day per install.
        deliverImmediateWarningsIfNeeded(for: config)
    }

    private static func schedule(id: String, title: String, body: String, at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private static func deliverImmediateWarningsIfNeeded(for config: ReNuvioConfig?) {
        guard let config else { return }
        let now = Date()
        let defaults = UserDefaults.standard

        for install in config.installs {
            guard let expiresAt = install.expiresAt else { continue }
            let remaining = expiresAt.timeIntervalSince(now)
            let deviceName = config.devices.first(where: { $0.id == install.deviceID })?.name ?? "device"
            let dayKey = "renuvio.expiry.nudge.\(install.id.uuidString)"
            let last = defaults.object(forKey: dayKey) as? Date
            if let last, now.timeIntervalSince(last) < 20 * 60 * 60 {
                continue
            }

            let content = UNMutableNotificationContent()
            content.sound = .default

            if remaining <= 0 {
                content.title = "\(install.name) expired"
                content.body = "Signing lapsed on \(deviceName). Open ReNuvio and renew."
            } else if remaining <= renewSoonLeadTime {
                let hours = max(1, Int(remaining / 3600))
                content.title = "\(install.name) expires soon"
                content.body = "About \(hours)h left on \(deviceName). Renew to keep it signed."
            } else {
                continue
            }

            defaults.set(now, forKey: dayKey)
            let request = UNNotificationRequest(
                identifier: "renuvio.expiry.nudge.\(install.id.uuidString).\(Int(now.timeIntervalSince1970))",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }
}
