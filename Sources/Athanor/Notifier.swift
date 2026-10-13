import AppKit
@preconcurrency import UserNotifications

/// Crash, restart and finish notifications, with Start again and Show log on
/// the crash one.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onStart: ((String) -> Void)?
    var onShowLog: ((String) -> Void)?
    private var asked = false

    /// Notifications need a bundle; a bare `swift run` binary has none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func setUp() {
        guard let center else { return }
        center.delegate = self
        let start = UNNotificationAction(identifier: "start", title: "Start Again")
        let log = UNNotificationAction(identifier: "log", title: "Show Log", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "down", actions: [start, log], intentIdentifiers: []),
            UNNotificationCategory(identifier: "info", actions: [log], intentIdentifiers: []),
        ])
    }

    func post(title: String, body: String, scriptID: String, down: Bool) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = down ? "down" : "info"
        content.userInfo = ["script": scriptID]
        if down { content.sound = .default }
        let request = UNNotificationRequest(identifier: "\(scriptID)-\(UUID().uuidString)", content: content, trigger: nil)
        let ask = !asked
        asked = true
        Task {
            if ask {
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            }
            try? await center.add(request)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.content.userInfo["script"] as? String
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let id else { return }
                if action == "start" {
                    self.onStart?(id)
                } else {
                    self.onShowLog?(id)
                }
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
