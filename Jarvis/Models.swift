import Foundation

enum Priority: String, Codable, CaseIterable, Identifiable {
    case low, normal, high, critical
    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: return "Düşük"
        case .normal: return "Normal"
        case .high: return "Yüksek"
        case .critical: return "Kritik"
        }
    }

    var rank: Int {
        switch self {
        case .critical: return 0
        case .high: return 1
        case .normal: return 2
        case .low: return 3
        }
    }
}

struct TaskItem: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var title: String
    var due: Date?
    var priority: Priority = .normal
    var done: Bool = false
    var createdAt: Date = Date()
    var alarmID: String?
}

struct ShoppingItem: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var createdAt: Date = Date()
}

struct CallItem: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var person: String
    var reason: String?
    var createdAt: Date = Date()
}

struct MemoryNote: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var text: String
    var createdAt: Date = Date()
}

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant }
    var id: String = UUID().uuidString
    var role: Role
    var text: String
    var date: Date = Date()
}

// MARK: - Sunucu sözleşmesi

struct ChatRequest: Encodable {
    struct HistoryItem: Encodable { let role: String; let content: String }
    struct Context: Encodable {
        struct T: Encodable { let id: String; let title: String; let due: String?; let priority: String }
        struct S: Encodable { let id: String; let name: String }
        struct C: Encodable { let id: String; let person: String; let reason: String? }
        struct E: Encodable { let start: String; let end: String?; let title: String; let location: String? }
        struct M: Encodable { let id: String; let text: String }
        let now: String
        let timezone: String
        let userName: String
        let assistantName: String
        let tasks: [T]
        let shopping: [S]
        let calls: [C]
        let events: [E]
        let memory: [M]
    }
    let message: String
    let history: [HistoryItem]
    let context: Context
}

struct ChatResponse: Decodable {
    let reply: String
    let actions: [AssistantAction]
}

struct AssistantAction: Decodable {
    let type: String
    let title: String?
    let items: [String]?
    let due: String?
    let end: String?
    let priority: String?
    let person: String?
    let origin: String?
    let destination: String?
    let location: String?
    let note: String?
    let target_id: String?
}

// MARK: - Tarih yardımcıları

enum DateText {
    /// Sunucu ile alışveriş biçimi: 2026-10-03T09:00 (yerel saat)
    static let wire: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()

    static let now: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd EEEE HH:mm"
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let d = wire.date(from: String(s.prefix(16))) { return d }
        let iso = ISO8601DateFormatter()
        return iso.date(from: s)
    }

    static func friendly(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "tr_TR")))
        if cal.isDateInToday(date) { return "Bugün \(time)" }
        if cal.isDateInTomorrow(date) { return "Yarın \(time)" }
        if cal.isDateInYesterday(date) { return "Dün \(time)" }
        return date.formatted(.dateTime.day().month(.wide).weekday(.abbreviated).hour().minute().locale(Locale(identifier: "tr_TR")))
    }
}
