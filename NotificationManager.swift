import Foundation
import UserNotifications

final class NotificationManager {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()

    private init() {}

    /// 启动时请求通知授权（只会弹一次系统框）
    func requestAuthorizationIfNeeded() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
}
