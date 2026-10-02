import Foundation
import SwiftUI

// MARK: - Özel günler (doğum günü, yıl dönümü…) · Anılar · Bayramlar

enum SpecialKind: String, Codable, CaseIterable, Identifiable {
    case birthday, anniversary, special
    var id: String { rawValue }

    var label: String {
        switch self {
        case .birthday: return "Doğum günü"
        case .anniversary: return "Yıl dönümü"
        case .special: return "Özel gün"
        }
    }

    var icon: String {
        switch self {
        case .birthday: return "gift.fill"
        case .anniversary: return "heart.fill"
        case .special: return "star.fill"
        }
    }

    var color: Color {
        switch self {
        case .birthday: return .pink
        case .anniversary: return .red
        case .special: return .yellow
        }
    }

    static func from(_ text: String?) -> SpecialKind {
        let t = (text ?? "").lowercased(with: Locale(identifier: "tr_TR"))
        if t.contains("doğum") || t.contains("birthday") { return .birthday }
        if t.contains("yıl dönüm") || t.contains("yıldönüm") || t.contains("evlilik") || t.contains("tanış") { return .anniversary }
        return .special
    }
}

/// Her yıl tekrar eden kişisel özel gün
struct SpecialDay: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var title: String
    var person: String?
    var month: Int
    var day: Int
    var year: Int?          // doğum / başlangıç yılı (biliniyorsa)
    var kind: SpecialKind = .special
    var note: String?

    /// Bugünden itibaren bir sonraki tarih
    func next(from now: Date = Date()) -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let y = cal.component(.year, from: today)
        for year in [y, y + 1, y + 2, y + 3, y + 4] {
            if let d = cal.date(from: DateComponents(year: year, month: month, day: day)), d >= today { return d }
        }
        return today
    }

    /// O tarihte kaçıncı yıl (doğum günü yaşı / yıl dönümü)
    func years(on date: Date) -> Int? {
        guard let year else { return nil }
        let n = Calendar.current.component(.year, from: date) - year
        return n > 0 ? n : nil
    }

    func occurs(on date: Date) -> Bool {
        let c = Calendar.current.dateComponents([.month, .day], from: date)
        return c.month == month && c.day == day
    }
}

/// Saklanan bir anı (geçmişte yaşanmış önemli olay)
struct Moment: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var title: String
    var date: Date
    var place: String?
    var note: String?
    var createdAt: Date = Date()
}

/// Türkiye'deki resmî ve dini bayramlar, anma ve kutlama günleri
struct Holiday: Identifiable, Hashable {
    enum Kind { case national, religious, observance }
    let title: String
    let date: Date
    let kind: Kind
    var id: String { title + DateText.dayKey(date) }

    var icon: String {
        switch kind {
        case .national: return "flag.fill"
        case .religious: return "moon.stars.fill"
        case .observance: return "sparkles"
        }
    }

    var color: Color {
        switch kind {
        case .national: return .red
        case .religious: return .green
        case .observance: return .purple
        }
    }

    static func list(year: Int) -> [Holiday] {
        let cal = Calendar.current
        func d(_ m: Int, _ day: Int, _ y: Int = year) -> Date? { cal.date(from: DateComponents(year: y, month: m, day: day)) }
        /// Ayın n'inci pazarı
        func nthSunday(_ n: Int, month: Int) -> Date? {
            guard let first = d(month, 1) else { return nil }
            let wd = cal.component(.weekday, from: first)   // 1 = pazar
            let offset = (8 - wd) % 7 + (n - 1) * 7
            return cal.date(byAdding: .day, value: offset, to: first)
        }

        var out: [Holiday] = []
        func add(_ title: String, _ date: Date?, _ kind: Kind) { if let date { out.append(Holiday(title: title, date: date, kind: kind)) } }

        add("Yılbaşı", d(1, 1), .national)
        add("Sevgililer Günü", d(2, 14), .observance)
        add("Dünya Kadınlar Günü", d(3, 8), .observance)
        add("Ulusal Egemenlik ve Çocuk Bayramı", d(4, 23), .national)
        add("Emek ve Dayanışma Günü", d(5, 1), .national)
        add("Anneler Günü", nthSunday(2, month: 5), .observance)
        add("Atatürk'ü Anma, Gençlik ve Spor Bayramı", d(5, 19), .national)
        add("Babalar Günü", nthSunday(3, month: 6), .observance)
        add("Demokrasi ve Millî Birlik Günü", d(7, 15), .national)
        add("Zafer Bayramı", d(8, 30), .national)
        add("Cumhuriyet Bayramı", d(10, 29), .national)
        add("Atatürk'ü Anma Günü", d(11, 10), .observance)
        add("Öğretmenler Günü", d(11, 24), .observance)

        // Dini bayramlar (Diyanet takvimi). Sonraki yıllar uygulama güncellemesiyle eklenir.
        let religious: [Int: [(String, Int, Int, Int)]] = [
            2026: [("Ramazan Bayramı Arifesi", 3, 19, 1), ("Ramazan Bayramı", 3, 20, 3),
                   ("Kurban Bayramı Arifesi", 5, 26, 1), ("Kurban Bayramı", 5, 27, 4)],
            2027: [("Ramazan Bayramı Arifesi", 3, 8, 1), ("Ramazan Bayramı", 3, 9, 3),
                   ("Kurban Bayramı Arifesi", 5, 15, 1), ("Kurban Bayramı", 5, 16, 4)]
        ]
        for (title, m, day, length) in religious[year] ?? [] {
            for i in 0..<length {
                guard let start = d(m, day), let date = cal.date(byAdding: .day, value: i, to: start) else { continue }
                let name = length > 1 ? "\(title) \(i + 1). gün" : title
                add(name, date, .religious)
            }
        }
        return out.sorted { $0.date < $1.date }
    }

    /// Belirli aralıktaki bayramlar
    static func between(_ start: Date, _ end: Date) -> [Holiday] {
        let cal = Calendar.current
        let y1 = cal.component(.year, from: start), y2 = cal.component(.year, from: end)
        return (y1...y2).flatMap { list(year: $0) }.filter { $0.date >= cal.startOfDay(for: start) && $0.date <= end }
    }
}

extension DateText {
    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static let dayOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "2026-10-01" ya da "2026-10-01T20:00" → tarih
    static func parseDay(_ s: String?) -> Date? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return parse(s) ?? dayOnly.date(from: String(s.prefix(10)))
    }

    static func long(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "tr_TR")))
    }

    static func dayMonth(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "tr_TR")))
    }
}
