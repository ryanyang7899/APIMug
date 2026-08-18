import AppKit
import Foundation
import UserNotifications

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()

    override private init() {
        super.init()
        center.delegate = self
    }

    /// 启动时请求通知授权（只会弹一次系统框）
    func requestAuthorizationIfNeeded() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 有新版本时通知（按版本去重，每个版本只提醒一次）
    func notifyUpdateAvailable(version: String, url: URL) {
        if version == ConfigStore.lastNotifiedVersion { return }
        ConfigStore.lastNotifiedVersion = version

        let content = UNMutableNotificationContent()
        content.title = "发现新版本 v\(version)"
        content.body = "APIMug 有新版本可用，点击前往下载"
        content.sound = .default
        content.userInfo = ["url": url.absoluteString]
        let request = UNNotificationRequest(identifier: "update-\(version)",
                                            content: content, trigger: nil)
        center.add(request) { _ in }
    }

    /// 低余额提醒，按天去重（同一站点同一天只提醒一次）
    func notifyLowBalance(site: Site, balance: Double, currency: String) {
        let today = AppFormatters.day.string(from: Date())
        if let last = ConfigStore.lastAlertDay(for: site.id), last == today {
            return
        }
        ConfigStore.setLastAlertDay(today, for: site.id)

        let title = "\(site.name) 余额不足"
        let body: String
        if currency == "CNY" {
            body = String(format: "当前余额 ¥%.2f，低于设定阈值", balance)
        } else {
            body = String(format: "当前余额 $%.2f，低于设定阈值", balance)
        }
        deliver(title: title, body: body, id: "low-balance-\(site.id.uuidString)-\(today)")
    }

    private func deliver(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(request) { _ in }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// 前台也显示横幅（菜单栏应用平时在后台，保险起见仍实现）
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// 点击通知 → 打开对应 URL（如 GitHub Release 页）
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let urlString = userInfo["url"] as? String, let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}
