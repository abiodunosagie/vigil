import Foundation
import UserNotifications

/// Mac notifications: a session finished, a session waits on the user, everything is done.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asks once; macOS remembers the answer.
    func askPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            // Only whether it worked, never what any notification said.
            NSLog("Vigil notifications allowed: %@, error: %@", granted ? "yes" : "no", Self.describe(error))
        }
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("Vigil notification not shown: %@", Self.describe(error)) }
        }
    }

    /// The error's type and code only, never a message that could quote content.
    nonisolated private static func describe(_ error: Error?) -> String {
        guard let error else { return "none" }
        return "\(type(of: error)) \((error as NSError).code)"
    }

    /// Show notifications even while the panel is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
