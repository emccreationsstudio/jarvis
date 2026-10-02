import Foundation
import UserNotifications
import SwiftUI
#if canImport(AlarmKit)
import AlarmKit
#endif

/// Önem sırasına göre hatırlatma:
/// low → sessiz bildirim · normal → sesli bildirim · high → sesli + 5 ve 10 dk sonra tekrar
/// critical → (iOS 26) alarm gibi çalar + 30 dk önce ön bildirim
@MainActor
final class Reminders {
    static let shared = Reminders()
    static let doneAction = "JARVIS_DONE"
    static let snoozeAction = "JARVIS_SNOOZE"
    static let category = "JARVIS_TASK"

    private let center = UNUserNotificationCenter.current()

    func registerCategories() {
        let done = UNNotificationAction(identifier: Self.doneAction, title: "Tamamlandı", options: [])
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "10 dk ertele", options: [])
        let cat = UNNotificationCategory(identifier: Self.category, actions: [done, snooze], intentIdentifiers: [], options: [])
        center.setNotificationCategories([cat])
    }

    @discardableResult
    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    private func ids(for task: TaskItem) -> [String] {
        ["\(task.id)-pre", "\(task.id)-0", "\(task.id)-1", "\(task.id)-2"]
    }

    func cancel(_ task: TaskItem) {
        center.removePendingNotificationRequests(withIdentifiers: ids(for: task))
        center.removeDeliveredNotifications(withIdentifiers: ids(for: task))
        if let alarmID = task.alarmID { cancelAlarm(alarmID) }
    }

    func schedule(_ task: TaskItem) {
        cancel(task)
        guard !task.done, let due = task.due, due > Date() else { return }

        switch task.priority {
        case .low:
            add(id: "\(task.id)-0", task: task, at: due, body: "Hatırlatma", sound: nil)
        case .normal:
            add(id: "\(task.id)-0", task: task, at: due, body: "Zamanı geldi", sound: .default)
        case .high:
            addRepeating(task, due: due)
        case .critical:
            let pre = due.addingTimeInterval(-30 * 60)
            if pre > Date() {
                add(id: "\(task.id)-pre", task: task, at: pre, body: "30 dakika sonra · önemli", sound: .default)
            }
            Task {
                if let alarmID = await scheduleAlarm(task, at: due) {
                    if var t = Store.shared.task(task.id) {
                        t.alarmID = alarmID
                        if let i = Store.shared.tasks.firstIndex(where: { $0.id == t.id }) { Store.shared.tasks[i] = t }
                    }
                } else {
                    addRepeating(task, due: due)
                }
            }
        }
    }

    private func addRepeating(_ task: TaskItem, due: Date) {
        add(id: "\(task.id)-0", task: task, at: due, body: "Önemli · zamanı geldi", sound: .default)
        add(id: "\(task.id)-1", task: task, at: due.addingTimeInterval(5 * 60), body: "Hâlâ bekliyor", sound: .default)
        add(id: "\(task.id)-2", task: task, at: due.addingTimeInterval(10 * 60), body: "Son hatırlatma", sound: .default)
    }

    private func add(id: String, task: TaskItem, at date: Date, body: String, sound: UNNotificationSound?) {
        let content = UNMutableNotificationContent()
        content.title = task.title
        content.body = body
        content.sound = sound
        content.categoryIdentifier = Self.category
        content.userInfo = ["taskID": task.id]
        if task.priority == .low { content.interruptionLevel = .passive }
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    // MARK: - AlarmKit (iOS 26)

    private func scheduleAlarm(_ task: TaskItem, at date: Date) async -> String? {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            do {
                let manager = AlarmManager.shared
                if manager.authorizationState != .authorized {
                    let state = try await manager.requestAuthorization()
                    guard state == .authorized else { return nil }
                }
                let alert = AlarmPresentation.Alert(
                    title: LocalizedStringResource(stringLiteral: task.title),
                    stopButton: AlarmButton(text: "Tamam", textColor: .white, systemImageName: "checkmark.circle")
                )
                let attributes = AlarmAttributes<JarvisAlarmMetadata>(
                    presentation: AlarmPresentation(alert: alert),
                    metadata: JarvisAlarmMetadata(),
                    tintColor: Color(red: 0.2, green: 0.6, blue: 1.0)
                )
                let id = UUID()
                let config = AlarmManager.AlarmConfiguration<JarvisAlarmMetadata>(
                    schedule: .fixed(date),
                    attributes: attributes
                )
                _ = try await manager.schedule(id: id, configuration: config)
                return id.uuidString
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    private func cancelAlarm(_ idString: String) {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), let id = UUID(uuidString: idString) {
            try? AlarmManager.shared.cancel(id: id)
        }
        #endif
    }

    func requestAlarmPermission() async -> Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            let state = (try? await AlarmManager.shared.requestAuthorization()) ?? .denied
            return state == .authorized
        }
        #endif
        return false
    }
}

#if canImport(AlarmKit)
@available(iOS 26.0, *)
struct JarvisAlarmMetadata: AlarmMetadata {}
#endif

/// Bildirimlerdeki "Tamamlandı" / "Ertele" düğmeleri ve uygulama açıkken bildirim gösterimi
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let taskID = response.notification.request.content.userInfo["taskID"] as? String else { return }
        let action = response.actionIdentifier
        await MainActor.run {
            let store = Store.shared
            if action == Reminders.doneAction {
                store.complete(taskID: taskID)
            } else if action == Reminders.snoozeAction, var t = store.task(taskID) {
                t.due = Date().addingTimeInterval(10 * 60)
                store.upsert(t)
            }
        }
    }
}
