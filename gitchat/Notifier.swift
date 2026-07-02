import AppKit
import UserNotifications

/// macOS notifications with inline reply. Only active when running from a real
/// .app bundle (UNUserNotificationCenter aborts for bare executables).
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    var onOpenChat: ((String) -> Void)?
    var onReply: ((String, String) -> Void)?
    var shouldSuppressBanner: ((String) -> Bool)?

    private var configured = false
    private var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    func configure() {
        guard available, !configured else { return }
        configured = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reply = UNTextInputNotificationAction(
            identifier: "REPLY", title: "Reply", options: [],
            textInputButtonTitle: "Send", textInputPlaceholder: "Message"
        )
        let open = UNNotificationAction(identifier: "OPEN", title: "Open", options: [.foreground])
        let category = UNNotificationCategory(identifier: "CHAT", actions: [reply, open],
                                              intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            gclog("notifications authorized: \(granted)")
        }
    }

    func post(_ item: NotificationItem) {
        guard available, configured else { return }
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.subtitle = item.subtitle
        content.body = item.body
        content.sound = .default
        content.categoryIdentifier = "CHAT"
        content.threadIdentifier = item.chatID
        content.userInfo = ["chatID": item.chatID]
        let request = UNNotificationRequest(
            identifier: "\(item.chatID)|\(UUID().uuidString)",
            content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Remove delivered notifications for a chat once it has been opened.
    func clearDelivered(for chatID: String) {
        guard available, configured else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered
                .filter { $0.request.content.threadIdentifier == chatID }
                .map { $0.request.identifier }
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let chatID = notification.request.content.userInfo["chatID"] as? String
        Task { @MainActor in
            if let chatID, self.shouldSuppressBanner?(chatID) == true {
                completionHandler([])
            } else {
                completionHandler([.banner, .sound])
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let chatID = response.notification.request.content.userInfo["chatID"] as? String
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            if let chatID {
                if action == "REPLY", let text, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.onReply?(chatID, text)
                } else {
                    self.onOpenChat?(chatID)
                }
            }
            completionHandler()
        }
    }
}
