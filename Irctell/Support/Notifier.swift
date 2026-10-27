import Foundation
import UserNotifications

/// Posts notifications; the system's in the app, a recording one in tests.
@MainActor
protocol Notifier: AnyObject {
    /// `threadID` groups a conversation's notifications, so they can be
    /// removed together once it is read.
    func post(title: String, subtitle: String, body: String, sound: Bool, threadID: String,
              userInfo: [String: String])
    func removeDelivered(threadID: String)
    /// Called with a clicked notification's user info.
    var onOpen: (([String: String]) -> Void)? { get set }
}

/// macOS notifications through the User Notifications framework. Permission
/// is asked for the first time one is posted; shown also while Irctell is in
/// front, as long as it is not the conversation being looked at -- which is
/// decided before posting.
@MainActor
final class SystemNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate {
    static let shared = SystemNotifier()

    var onOpen: (([String: String]) -> Void)?
    private var askedForPermission = false
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func post(title: String, subtitle: String, body: String, sound: Bool, threadID: String,
              userInfo: [String: String]) {
        if !askedForPermission {
            askedForPermission = true
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
                if let error { AppLog.warning("notifications", "notifications not allowed: \(error)") }
            }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.threadIdentifier = threadID
        content.userInfo = userInfo
        if sound { content.sound = .default }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func removeDelivered(threadID: String) {
        Task {
            let delivered = await center.deliveredNotifications()
            let ids = delivered.filter { $0.request.content.threadIdentifier == threadID }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        var strings: [String: String] = [:]
        for (key, value) in info {
            if let key = key as? String, let value = value as? String { strings[key] = value }
        }
        await MainActor.run { [strings] in onOpen?(strings) }
    }
}
