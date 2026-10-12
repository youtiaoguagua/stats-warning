import AppKit
import UserNotifications
import TemperatureCore

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    var onOpen: (() -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    func authorization() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func send(title: String, body: String, sound: Bool) async throws {
        let status = await authorization()
        guard status == .authorized || status == .provisional else {
            throw NotificationError.notAuthorized
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        // Reusing an identifier updates an existing notification. Use a fresh request
        // for each event so repeated tests / later hot episodes can show a new banner.
        // Keep storage bounded without replacing a notification being presented.
        let delivered = await center.deliveredNotifications()
        let previous = delivered.filter {
            $0.request.identifier == "temperature-warning" || $0.request.identifier.hasPrefix("temperature-warning-")
        }.sorted { $0.date > $1.date }
        let expired = previous.dropFirst(4).map { $0.request.identifier }
        if !expired.isEmpty { center.removeDeliveredNotifications(withIdentifiers: expired) }
        content.threadIdentifier = "temperature-warning"
        let request = UNNotificationRequest(identifier: "temperature-warning-" + UUID().uuidString, content: content, trigger: nil)
        try await center.add(request)
    }

    func testDeliveryMessage() async -> String {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .provisional {
            return "测试已提交，但当前为静默通知授权，请在「通知设置」开启桌面提醒。"
        }
        if settings.alertSetting == .disabled {
            return "测试已提交，但桌面提醒已关闭，请在「通知设置」开启。"
        }
        return "测试已提交。若无横幅，请检查专注模式及共享屏幕时的通知设置。"
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if notification.request.content.sound != nil { options.insert(.sound) }
        completionHandler(options)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor [weak self] in self?.onOpen?() }
        completionHandler()
    }
}

private enum NotificationError: LocalizedError {
    case notAuthorized
    var errorDescription: String? { "通知尚未授权，请允许通知后再试。" }
}
