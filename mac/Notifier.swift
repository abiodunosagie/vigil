import Foundation
import UserNotifications

/// Mac notifications, with the user's sounds, quiet hours and phone copy.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Kind { case finished, waiting, allDone, warning }

    /// Called with the session id when the user clicks a session's notification.
    var onOpenSession: ((String) -> Void)?
    private let settings: VigilSettings
    nonisolated private static let sessionKey = "session"

    init(settings: VigilSettings) {
        self.settings = settings
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

    func post(_ kind: Kind, title: String, body: String, session: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let session { content.userInfo = [Self.sessionKey: session] }
        if !settings.soundsOff(), let name = soundName(kind) {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(name + ".aiff"))
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("Vigil notification not shown: %@", Self.describe(error)) }
        }
        if settings.phoneAlerts {
            PhoneAlerts.send(title: title, body: body, to: settings.ntfyURL)
        }
    }

    private func soundName(_ kind: Kind) -> String? {
        switch kind {
        case .finished: settings.finishedSound
        case .waiting: settings.waitingSound
        case .allDone: settings.allDoneSound
        case .warning: VigilSettings.warningSound
        }
    }

    /// The error's type and code only, never a message that could quote content.
    nonisolated private static func describe(_ error: Error?) -> String {
        guard let error else { return "none" }
        return "\(type(of: error)) \((error as NSError).code)"
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let session = response.notification.request.content.userInfo[Self.sessionKey] as? String
        Task { @MainActor in
            if let session, response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                self.onOpenSession?(session)
            }
            completionHandler()
        }
    }

    /// Show notifications even while the panel is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
