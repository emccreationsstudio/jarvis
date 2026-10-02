import Foundation
import EventKit

/// iPhone'un takvim sistemi: iCloud, Google, Outlook — telefonda kayıtlı tüm takvimler.
@MainActor
final class CalendarService {
    static let shared = CalendarService()
    private let store = EKEventStore()

    var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    @discardableResult
    func requestAccess() async -> Bool {
        if hasAccess { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    struct Event {
        let start: Date
        let end: Date?
        let title: String
        let location: String?
    }

    func upcoming(days: Int = 3) -> [Event] {
        guard hasAccess else { return [] }
        let start = Calendar.current.startOfDay(for: Date())
        guard let end = Calendar.current.date(byAdding: .day, value: days, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(40)
            .map { Event(start: $0.startDate, end: $0.isAllDay ? nil : $0.endDate, title: $0.title ?? "Etkinlik", location: $0.location) }
    }

    /// Belirli aralıktaki etkinlikler (haftalık / yıllık görünüm için)
    func events(from start: Date, to end: Date) -> [Event] {
        guard hasAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { Event(start: $0.startDate, end: $0.isAllDay ? nil : $0.endDate, title: $0.title ?? "Etkinlik", location: $0.location) }
    }

    /// Takvime etkinlik ekler; başarılıysa true.
    func add(title: String, start: Date, end: Date?, location: String?, important: Bool) async -> Bool {
        guard await requestAccess(), let calendar = store.defaultCalendarForNewEvents else { return false }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = end ?? start.addingTimeInterval(60 * 60)
        if let location, !location.isEmpty { event.location = location }
        event.addAlarm(EKAlarm(relativeOffset: important ? -60 * 60 : -30 * 60))
        do {
            try store.save(event, span: .thisEvent)
            return true
        } catch {
            return false
        }
    }
}
