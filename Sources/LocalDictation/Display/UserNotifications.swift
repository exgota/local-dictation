import UserNotifications

/// User notifications. The recording watchdog, which stops a recording at its maximum duration, is the only sender.
/// Authorization is requested the first time a notification is posted, never at launch.
enum UserNotifications {
    static func post(title: String, body: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
