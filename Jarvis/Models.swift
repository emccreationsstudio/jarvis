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
    /// Ne zaman tamamlandı (bugün tamamlananlar listede üstü çizili görünür)
    var doneAt: Date?
}

struct ShoppingItem: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var createdAt: Date = Date()
    /// Alındı işareti (dokununca işaretlenir, silinmez)
    var done: Bool = false
}

struct CallItem: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var person: String
    var reason: String?
    var createdAt: Date = Date()
    /// Arandı işareti
    var done: Bool = false
}

// Eski kayıtlarda "done" alanı yok → eksikse false say (yoksa tüm veri okunamazdı).
// Uzantıda tanımlandığı için hazır (memberwise) kurucular da kalır.
extension ShoppingItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
    }
}

extension CallItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        person = try c.decode(String.self, forKey: .person)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
    }
}

/// Kullanıcının kendi açtığı listelerin satırı (Eczane, Günlük ilaçlar…)
struct ListItem: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var text: String
    var done: Bool = false
    var createdAt: Date = Date()
}

extension ListItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        text = try c.decode(String.self, forKey: .text)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// Kullanıcının açtığı liste. "Günlük" listelerde işaretler her sabah sıfırlanır (ör. günlük ilaçlar).
struct CustomList: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var icon: String = "list.bullet"
    var daily: Bool = false
    var items: [ListItem] = []
    var createdAt: Date = Date()
    /// Günlük listenin en son sıfırlandığı gün (yyyy-MM-dd)
    var lastReset: String?

    var openCount: Int { items.filter { !$0.done }.count }

    /// Liste adına göre uygun simge
    static func icon(for name: String) -> String {
        let n = name.lowercased(with: Locale(identifier: "tr_TR"))
        if n.contains("ilaç") || n.contains("eczane") || n.contains("vitamin") { return "pills.fill" }
        if n.contains("market") || n.contains("alışveriş") { return "cart.fill" }
        if n.contains("film") || n.contains("dizi") { return "film" }
        if n.contains("kitap") { return "book.fill" }
        if n.contains("şarkı") || n.contains("müzik") || n.contains("stüdyo") { return "music.note" }
        if n.contains("hediye") { return "gift.fill" }
        if n.contains("yol") || n.contains("tatil") || n.contains("bavul") { return "suitcase.fill" }
        if n.contains("iş") || n.contains("proje") { return "briefcase.fill" }
        return "list.bullet"
    }
}

extension CustomList {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? CustomList.icon(for: name)
        daily = try c.decodeIfPresent(Bool.self, forKey: .daily) ?? false
        items = try c.decodeIfPresent([ListItem].self, forKey: .items) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastReset = try c.decodeIfPresent(String.self, forKey: .lastReset)
    }
}

/// Silinen her şey önce buraya gelir; 30 gün içinde geri alınabilir.
struct TrashEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case task, shopping, call, memory, listItem, list }
    var id: String = UUID().uuidString
    var kind: Kind
    var deletedAt: Date = Date()
    var task: TaskItem?
    var shopping: ShoppingItem?
    var call: CallItem?
    var memory: MemoryNote?
    var listItem: ListItem?
    /// listItem için: hangi listeden silindi
    var listID: String?
    var listName: String?
    var list: CustomList?

    var title: String {
        switch kind {
        case .task: return task?.title ?? "Görev"
        case .shopping: return shopping?.name ?? "Ürün"
        case .call: return call?.person ?? "Arama"
        case .memory: return memory?.text ?? "Hafıza kaydı"
        case .listItem: return listItem?.text ?? "Liste satırı"
        case .list: return list?.name ?? "Liste"
        }
    }

    var source: String {
        switch kind {
        case .task: return "Görevler"
        case .shopping: return "Alışveriş"
        case .call: return "Aranacaklar"
        case .memory: return "Hafıza"
        case .listItem: return listName ?? "Liste"
        case .list: return "Liste (\(list?.items.count ?? 0) satır)"
        }
    }

    var icon: String {
        switch kind {
        case .task: return "checklist"
        case .shopping: return "cart"
        case .call: return "phone"
        case .memory: return "brain.head.profile"
        case .listItem: return "list.bullet"
        case .list: return "folder"
        }
    }
}

extension TrashEntry {
    /// İçerik bozuksa yine de açılsın (ör. başka cihazdan eksik alanla gelmişse)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try c.decode(Kind.self, forKey: .kind)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt) ?? Date()
        task = try? c.decodeIfPresent(TaskItem.self, forKey: .task)
        shopping = try? c.decodeIfPresent(ShoppingItem.self, forKey: .shopping)
        call = try? c.decodeIfPresent(CallItem.self, forKey: .call)
        memory = try? c.decodeIfPresent(MemoryNote.self, forKey: .memory)
        listItem = try? c.decodeIfPresent(ListItem.self, forKey: .listItem)
        listID = try? c.decodeIfPresent(String.self, forKey: .listID)
        listName = try? c.decodeIfPresent(String.self, forKey: .listName)
        list = try? c.decodeIfPresent(CustomList.self, forKey: .list)
    }
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
        struct E: Encodable { let id: String?; let start: String; let end: String?; let title: String; let location: String? }
        struct L: Encodable { let id: String; let name: String; let daily: Bool; let items: [String]; let done: [String] }
        struct Loc: Encodable { let lat: Double; let lon: Double }
        struct M: Encodable { let id: String; let text: String }
        struct SD: Encodable { let id: String; let title: String; let person: String?; let kind: String; let next: String; let years: Int? }
        struct H: Encodable { let date: String; let title: String }
        struct MO: Encodable { let date: String; let title: String; let place: String?; let note: String? }
        let now: String
        let timezone: String
        let userName: String
        let assistantName: String
        let tasks: [T]
        let shopping: [S]
        let calls: [C]
        let events: [E]
        let memory: [M]
        let specials: [SD]
        let holidays: [H]
        let moments: [MO]
        let lists: [L]
        /// Hava durumu için yaklaşık konum (izin varsa)
        let location: Loc?
    }
    let message: String
    let history: [HistoryItem]
    let context: Context
    /// Mesaj sesle mi söylendi (sunucu yanlış duyulmuş sözcükleri düzeltmeye çalışır)
    var voice: Bool = false
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
