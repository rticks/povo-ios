import Foundation
import UserNotifications
import PovoKit

@MainActor
final class SuspensionNotifier {
    private let center = UNUserNotificationCenter.current()
    private let prefix = "povo-suspension-"
    func requestPermission() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }
    func sync(accounts: [AccountRecord], preferences: PreferencesStore) async throws {
        let settings = preferences.value
        let pending = await center.pendingNotificationRequests()
        let ours = pending.filter { $0.identifier.hasPrefix(prefix) }
        let delivered = await center.deliveredNotifications()
        let permission = await center.notificationSettings().authorizationStatus
        guard settings.suspensionEnabled, settings.notifySuspension,
              [.authorized, .provisional, .ephemeral].contains(permission) else {
            center.removePendingNotificationRequests(withIdentifiers: ours.map(\.identifier)); return
        }
        let today = CalendarDay(date: Date())
        var wanted = Set<String>()
        for account in accounts {
            guard let anchor = preferences.anchors[account.id], let forecast = anchor.forecast(today: today) else { continue }
            let id = prefix + account.id
            wanted.insert(id)
            if anchor.notifiedFor == forecast.suspendsOn.description { continue }
            if delivered.contains(where: { $0.request.identifier == id && $0.request.content.userInfo["suspendsOn"] as? String == forecast.suspendsOn.description }) {
                try preferences.markNotified(account.id, date: forecast.suspendsOn.description)
                continue
            }
            let warnDay = forecast.suspendsOn.adding(days: -settings.notifyDays)
            let content = UNMutableNotificationContent()
            content.title = "povo 利用停止の予定を確認してください"
            content.body = "\(account.label)：\(forecast.suspendsOn) 以降、順次利用停止の可能性があります。起算日は手入力した内容に基づきます。"
            content.sound = .default
            content.userInfo = ["accountID": account.id, "suspendsOn": forecast.suspendsOn.description]
            let trigger: UNNotificationTrigger
            let immediate = warnDay <= today
            if immediate { trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false) }
            else {
                var components = DateComponents()
                components.calendar = Calendar(identifier: .gregorian)
                components.timeZone = .current
                components.year = warnDay.year; components.month = warnDay.month; components.day = warnDay.day; components.hour = 9
                trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            }
            // Scheduling a future local notification doesn't depend on iOS ever
            // granting the app another background execution slot.
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            if immediate { try preferences.markNotified(account.id, date: forecast.suspendsOn.description) }
        }
        center.removePendingNotificationRequests(withIdentifiers: ours.filter { !wanted.contains($0.identifier) }.map(\.identifier))
    }
    func remove(accountID: String) {
        center.removePendingNotificationRequests(withIdentifiers: [prefix + accountID])
        center.removeDeliveredNotifications(withIdentifiers: [prefix + accountID])
    }
}
