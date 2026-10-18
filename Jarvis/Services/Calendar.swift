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

    struct Event: Identifiable {
        /// Takvimdeki kimliği (düzenleme / silme için)
        let id: String?
        let start: Date
        let end: Date?
        let title: String
        let location: String?
        var allDay: Bool = false
        var calendarTitle: String? = nil
        var editable: Bool = false
    }

    func upcoming(days: Int = 3) -> [Event] {
        guard hasAccess else { return [] }
        let start = Calendar.current.startOfDay(for: Date())
        guard let end = Calendar.current.date(byAdding: .day, value: days, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(40)
            .map(Self.make)
    }

    /// Belirli aralıktaki etkinlikler (haftalık / yıllık görünüm için)
    func events(from start: Date, to end: Date) -> [Event] {
        guard hasAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map(Self.make)
    }

    private static func make(_ e: EKEvent) -> Event {
        Event(id: e.eventIdentifier, start: e.startDate, end: e.isAllDay ? nil : e.endDate,
              title: e.title ?? "Etkinlik", location: e.location,
              allDay: e.isAllDay, calendarTitle: e.calendar?.title,
              editable: e.calendar?.allowsContentModifications ?? false)
    }

    func event(id: String) -> Event? {
        guard hasAccess, let e = store.event(withIdentifier: id) else { return nil }
        return Self.make(e)
    }

    /// Etkinliği değiştirir (başlık, zaman, yer). Sadece başlangıç verilirse süresi korunur → erteleme.
    func update(id: String, title: String?, start: Date?, end: Date?, location: String?) async -> Bool {
        guard await requestAccess(), let e = store.event(withIdentifier: id),
              e.calendar?.allowsContentModifications ?? false else { return false }
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { e.title = title }
        if let start {
            let duration = e.endDate.timeIntervalSince(e.startDate)
            e.startDate = start
            e.endDate = end ?? start.addingTimeInterval(max(duration, 15 * 60))
        } else if let end {
            e.endDate = end
        }
        if let location { e.location = location.isEmpty ? nil : location }
        do {
            try store.save(e, span: .thisEvent)
            return true
        } catch {
            return false
        }
    }

    func delete(id: String) async -> Bool {
        guard await requestAccess(), let e = store.event(withIdentifier: id),
              e.calendar?.allowsContentModifications ?? false else { return false }
        do {
            try store.remove(e, span: .thisEvent)
            return true
        } catch {
            return false
        }
    }

    /// Etkinlik eklenebilen (yazılabilir) takvimler
    struct CalendarInfo: Identifiable, Hashable { let id: String; let title: String }
    func writableCalendars() -> [CalendarInfo] {
        guard hasAccess else { return [] }
        return store.calendars(for: .event)
            .filter { $0.allowsContentModifications }
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title) }
    }
    var defaultCalendarID: String? { store.defaultCalendarForNewEvents?.calendarIdentifier }

    /// Salt okunur bir etkinliğin düzenlenebilir kopyasını varsayılan takvime ekler; yeni kimliği döner.
    func duplicate(id: String) async -> String? {
        guard await requestAccess(), let src = store.event(withIdentifier: id),
              let cal = store.defaultCalendarForNewEvents else { return nil }
        let e = EKEvent(eventStore: store)
        e.calendar = cal
        e.title = src.title
        e.startDate = src.startDate
        e.endDate = src.endDate
        e.isAllDay = src.isAllDay
        e.location = src.location
        e.notes = src.notes
        do { try store.save(e, span: .thisEvent); return e.eventIdentifier } catch { return nil }
    }

    /// Takvime etkinlik ekler; başarılıysa true.
    func add(title: String, start: Date, end: Date?, location: String?, important: Bool,
             allDay: Bool = false, calendarID: String? = nil) async -> Bool {
        guard await requestAccess() else { return false }
        let chosen = calendarID.flatMap { store.calendar(withIdentifier: $0) }
        guard let calendar = (chosen?.allowsContentModifications == true ? chosen : nil) ?? store.defaultCalendarForNewEvents
        else { return false }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.isAllDay = allDay
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
