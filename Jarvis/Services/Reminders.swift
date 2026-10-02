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

        // "Tüm hatırlatmalar alarm gibi" açıksa normal önemdekiler de alarm olarak çalar
        let asAlarm = task.priority == .critical || task.priority == .high
            || (task.priority == .normal && AppSettings.shared.alarmAll)

        switch task.priority {
        case .low:
            add(id: "\(task.id)-0", task: task, at: due, body: "Hatırlatma", sound: nil)
        case .normal where !asAlarm:
            add(id: "\(task.id)-0", task: task, at: due, body: "Zamanı geldi", sound: .default)
        default:
            if task.priority == .critical {
                let pre = due.addingTimeInterval(-30 * 60)
                if pre > Date() {
                    add(id: "\(task.id)-pre", task: task, at: pre, body: "30 dakika sonra · önemli", sound: .default)
                }
            }
            Task {
                let result = await scheduleAlarm(title: task.title, at: due)
                if let alarmID = result.id {
                    if var t = Store.shared.task(task.id) {
                        t.alarmID = alarmID
                        if let i = Store.shared.tasks.firstIndex(where: { $0.id == t.id }) { Store.shared.tasks[i] = t }
                    }
                } else {
                    lastAlarmError = result.error
                    addRepeating(task, due: due)   // alarm kurulamazsa: tekrarlayan sesli bildirim
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

    // MARK: - Özel günler ve bayramlar

    /// Her yıl tekrar eder: 1 hafta önce 10:00 ve o gün 09:00
    func scheduleSpecial(_ d: SpecialDay) {
        cancelSpecial(d)
        let who = d.person.map { " · \($0)" } ?? ""
        addYearly(id: "\(d.id)-sd-0", title: "Bugün: \(d.title)", body: d.kind.label + who, month: d.month, day: d.day, hour: 9)
        // 7 gün öncesi: ay/gün hesabı (artık yıl farkı önemsiz)
        let cal = Calendar.current
        if let ref = cal.date(from: DateComponents(year: 2027, month: d.month, day: d.day)),
           let before = cal.date(byAdding: .day, value: -7, to: ref) {
            let c = cal.dateComponents([.month, .day], from: before)
            addYearly(id: "\(d.id)-sd-7", title: "1 hafta sonra: \(d.title)", body: d.kind == .birthday ? "Hediye ya da kutlama planı için zaman var." : d.kind.label + who,
                      month: c.month ?? d.month, day: c.day ?? d.day, hour: 10)
        }
    }

    func cancelSpecial(_ d: SpecialDay) {
        center.removePendingNotificationRequests(withIdentifiers: ["\(d.id)-sd-0", "\(d.id)-sd-7"])
    }

    private func addYearly(id: String, title: String, body: String, month: Int, day: Int, hour: Int) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(month: month, day: day, hour: hour, minute: 0), repeats: true)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// Önümüzdeki 12 ayın bayram ve özel günleri: bir gün önce 20:00 (Anneler/Babalar/Sevgililer günü 3 gün önce)
    func scheduleHolidays() {
        let cal = Calendar.current
        let now = Date()
        guard let end = cal.date(byAdding: .month, value: 12, to: now) else { return }
        var keep: Set<String> = []
        for h in Holiday.between(now, end) where !h.title.contains(". gün") || h.title.hasSuffix("1. gün") {
            let gift = ["Anneler Günü", "Babalar Günü", "Sevgililer Günü"].contains(h.title)
            guard let at = cal.date(byAdding: .day, value: gift ? -3 : -1, to: h.date),
                  let fire = cal.date(bySettingHour: 20, minute: 0, second: 0, of: at), fire > now else { continue }
            let name = h.title.replacingOccurrences(of: " 1. gün", with: "")
            let content = UNMutableNotificationContent()
            content.title = gift ? "3 gün sonra: \(name)" : "Yarın: \(name)"
            content.body = gift ? "Bir hediye ya da sürpriz düşünmek ister misin?" : "Planlarını buna göre yapabilirsin."
            content.sound = .default
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            // Sabit kimlik: aynı bayram tekrar kurulursa üzerine yazılır
            let id = "hol-" + DateText.dayKey(h.date) + "-" + String(name.filter { $0.isLetter || $0.isNumber }.prefix(24))
            keep.insert(id)
            center.add(UNNotificationRequest(identifier: id, content: content,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        }
        let wanted = keep
        center.getPendingNotificationRequests { [center] pending in
            let stale = pending.map(\.identifier).filter { $0.hasPrefix("hol-") && !wanted.contains($0) }
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }
    }

    // MARK: - AlarmKit (iOS 26)

    /// Son alarm kurma hatası (Ayarlar'da gösterilir)
    private(set) var lastAlarmError: String?

    /// Ayarlar → "Alarmı dene": 10 saniye sonra çalan deneme alarmı
    func testAlarm() async -> String {
        let result = await scheduleAlarm(title: "Jarvis alarm testi", at: Date().addingTimeInterval(10))
        if result.id != nil { return "Alarm 10 saniye sonra çalacak. Telefonu kilitleyip bekleyebilirsin." }
        return "Alarm kurulamadı: \(result.error ?? "bilinmeyen hata")"
    }

    private func scheduleAlarm(title: String, at date: Date) async -> (id: String?, error: String?) {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            do {
                let manager = AlarmManager.shared
                if manager.authorizationState != .authorized {
                    let state = try await manager.requestAuthorization()
                    guard state == .authorized else {
                        return (nil, "Alarm izni kapalı. iPhone Ayarları → Jarvis → Alarmlar'ı açın.")
                    }
                }
                let alert = AlarmPresentation.Alert(
                    title: LocalizedStringResource(stringLiteral: title),
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
                lastAlarmError = nil
                return (id.uuidString, nil)
            } catch {
                return (nil, error.localizedDescription)
            }
        }
        #endif
        return (nil, "Alarm özelliği iOS 26 ve sonrasında çalışır.")
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
