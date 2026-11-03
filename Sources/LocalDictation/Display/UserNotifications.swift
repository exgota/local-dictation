import UserNotifications

/// The recording watchdog requests authorization when it first posts. Update reminders use existing authorization.
enum UserNotifications {
    private static let updateAvailableIdentifier = "LocalDictation.UpdateAvailable"
    @MainActor private static let delegate = NotificationDelegate()
    @MainActor private static var updateAction: (() -> Void)?
    @MainActor private static var updateNotificationTask: Task<Void, Never>?

    @MainActor static func configureUpdateAction(_ action: @escaping () -> Void) {
        updateAction = action
        UNUserNotificationCenter.current().delegate = delegate
    }

    @MainActor static func postUpdateAvailable(displayVersion: String) {
        let previous = updateNotificationTask
        previous?.cancel()
        updateNotificationTask = Task {
            // Finish any cancelled delivery before reusing the notification identifier.
            await previous?.value
            guard !Task.isCancelled else { return }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard !Task.isCancelled,
                  settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Local Dictation update available"
            content.body = "Version \(displayVersion) is ready to install."
            let request = UNNotificationRequest(identifier: updateAvailableIdentifier, content: content, trigger: nil)
            try? await center.add(request)
            if Task.isCancelled { removeUpdateNotification(from: center) }
        }
    }

    @MainActor static func removeUpdateAvailable() {
        updateNotificationTask?.cancel()
        removeUpdateNotification(from: .current())
    }

    private static func removeUpdateNotification(from center: UNUserNotificationCenter) {
        center.removePendingNotificationRequests(withIdentifiers: [updateAvailableIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [updateAvailableIdentifier])
    }

    private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            guard response.notification.request.identifier == updateAvailableIdentifier,
                  response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
            await MainActor.run { updateAction?() }
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter, willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            notification.request.identifier == updateAvailableIdentifier ? [.banner, .list] : []
        }
    }

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
