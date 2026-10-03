import Foundation
import Security

/// Görevler, listeler, hafıza ve sohbet geçmişi — telefonda JSON olarak saklanır.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var tasks: [TaskItem] = [] { didSet { save() } }
    @Published var shopping: [ShoppingItem] = [] { didSet { save() } }
    @Published var calls: [CallItem] = [] { didSet { save() } }
    @Published var memory: [MemoryNote] = [] { didSet { save() } }
    @Published var messages: [ChatMessage] = [] { didSet { save() } }
    @Published var specials: [SpecialDay] = [] { didSet { save() } }
    @Published var moments: [Moment] = [] { didSet { save() } }

    /// Diskte ve eşitlemede kullanılan tek veri biçimi (bilgisayar uygulaması da aynısını kullanır)
    struct Snapshot: Codable {
        var tasks: [TaskItem]
        var shopping: [ShoppingItem]
        var calls: [CallItem]
        var memory: [MemoryNote]
        var messages: [ChatMessage]
        // Sonradan eklenenler: eski kayıtlarda yok → isteğe bağlı
        var specials: [SpecialDay]?
        var moments: [Moment]?
        var updatedAt: Date?
    }

    /// Son yerel değişiklik zamanı (eşitlemede hangisi yeni, ona göre karar verilir)
    private(set) var updatedAt: Date = .distantPast
    private var applyingRemote = false

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// Hem "2026-10-03T10:00:00Z" hem "2026-10-03T10:00:00.123Z" biçimini okur
    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            let plain = ISO8601DateFormatter()
            let frac = ISO8601DateFormatter()
            frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = plain.date(from: s) ?? frac.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Tarih okunamadı: \(s)")
        }
        return d
    }

    var snapshot: Snapshot {
        Snapshot(tasks: tasks, shopping: shopping, calls: calls, memory: memory,
                 messages: Array(messages.suffix(200)), specials: specials, moments: moments, updatedAt: updatedAt)
    }

    /// Eşitlemeden gelen daha yeni veriyi uygula (hatırlatmaları da günceller)
    func applyRemote(_ snap: Snapshot, updatedAt remoteDate: Date) {
        applyingRemote = true
        defer { applyingRemote = false }

        let oldTasks = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let oldSpecials = Dictionary(specials.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Bu cihaza ait alarm kimliklerini koru
        tasks = snap.tasks.map { t in
            var t = t
            t.alarmID = oldTasks[t.id]?.alarmID
            return t
        }
        shopping = snap.shopping
        calls = snap.calls
        memory = snap.memory
        messages = snap.messages
        specials = snap.specials ?? []
        moments = snap.moments ?? []
        updatedAt = remoteDate

        // Yalnızca değişen hatırlatmaları yeniden kur
        let newIDs = Set(tasks.map(\.id))
        for (id, old) in oldTasks where !newIDs.contains(id) { Reminders.shared.cancel(old) }
        for t in tasks {
            let old = oldTasks[t.id]
            if old == nil || old!.due != t.due || old!.priority != t.priority || old!.done != t.done || old!.title != t.title {
                if t.done, let old { Reminders.shared.cancel(old) } else { Reminders.shared.schedule(t) }
            }
        }
        let newSpecialIDs = Set(specials.map(\.id))
        for (id, old) in oldSpecials where !newSpecialIDs.contains(id) { Reminders.shared.cancelSpecial(old) }
        for d in specials where oldSpecials[d.id] != d { Reminders.shared.scheduleSpecial(d) }
        writeToDisk()
    }

    private var loading = false
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("jarvis-data.json")
    }()

    private init() { load() }

    private func load() {
        loading = true
        defer { loading = false }
        guard let data = try? Data(contentsOf: url) else { return }
        guard let snap = try? Self.makeDecoder().decode(Snapshot.self, from: data) else { return }
        tasks = snap.tasks
        shopping = snap.shopping
        calls = snap.calls
        memory = snap.memory
        messages = snap.messages
        specials = snap.specials ?? []
        moments = snap.moments ?? []
        updatedAt = snap.updatedAt ?? .distantPast
    }

    private func save() {
        guard !loading, !applyingRemote else { return }
        updatedAt = Date()
        writeToDisk()
        SyncService.shared.schedulePush()
    }

    private func writeToDisk() {
        if let data = try? Self.makeEncoder().encode(snapshot) {
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }

    // MARK: Özel günler ve anılar

    func addSpecial(_ day: SpecialDay) {
        // Aynı gün + aynı başlık varsa güncelle
        if let i = specials.firstIndex(where: {
            $0.month == day.month && $0.day == day.day
                && $0.title.lowercased(with: Locale(identifier: "tr_TR")) == day.title.lowercased(with: Locale(identifier: "tr_TR"))
        }) {
            var d = day; d.id = specials[i].id
            specials[i] = d
        } else {
            specials.append(day)
        }
        Reminders.shared.scheduleSpecial(specials.first { $0.month == day.month && $0.day == day.day && $0.title == day.title } ?? day)
    }

    func removeSpecial(id: String) {
        if let d = specials.first(where: { $0.id == id }) { Reminders.shared.cancelSpecial(d) }
        specials.removeAll { $0.id == id }
    }

    func addMoment(_ m: Moment) {
        moments.append(m)
        moments.sort { $0.date > $1.date }
    }

    /// Belirli bir güne düşen özel günler
    func specials(on date: Date) -> [SpecialDay] { specials.filter { $0.occurs(on: date) } }

    func moments(on date: Date) -> [Moment] {
        moments.filter { Calendar.current.isDate($0.date, inSameDayAs: date) }
    }

    func tasks(on date: Date) -> [TaskItem] {
        tasks.filter { t in
            guard let due = t.due else { return false }
            return Calendar.current.isDate(due, inSameDayAs: date)
        }
        .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    // MARK: Görevler

    var openTasks: [TaskItem] {
        tasks.filter { !$0.done }.sorted { a, b in
            switch (a.due, b.due) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.priority.rank < b.priority.rank
            }
        }
    }

    func task(_ id: String?) -> TaskItem? {
        guard let id else { return nil }
        return tasks.first { $0.id == id }
    }

    func upsert(_ task: TaskItem) {
        if let i = tasks.firstIndex(where: { $0.id == task.id }) { tasks[i] = task } else { tasks.append(task) }
        Reminders.shared.schedule(task)
    }

    func complete(taskID: String) {
        guard let i = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[i].done = true
        Reminders.shared.cancel(tasks[i])
        // Eski tamamlanmışları temizle (son 50'yi tut)
        let doneOnes = tasks.filter { $0.done }
        if doneOnes.count > 50 {
            let drop = Set(doneOnes.sorted { $0.createdAt < $1.createdAt }.prefix(doneOnes.count - 50).map(\.id))
            tasks.removeAll { drop.contains($0.id) }
        }
    }

    func delete(taskID: String) {
        guard let t = task(taskID) else { return }
        Reminders.shared.cancel(t)
        tasks.removeAll { $0.id == taskID }
    }

    // MARK: Alışveriş

    func addShopping(_ names: [String]) -> [String] {
        var added: [String] = []
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if shopping.contains(where: { $0.name.lowercased(with: Locale(identifier: "tr_TR")) == name.lowercased(with: Locale(identifier: "tr_TR")) }) { continue }
            shopping.append(ShoppingItem(name: name.prefix(1).uppercased(with: Locale(identifier: "tr_TR")) + name.dropFirst()))
            added.append(name)
        }
        return added
    }

    func removeShopping(_ names: [String]) {
        let tr = Locale(identifier: "tr_TR")
        for raw in names {
            let key = raw.lowercased(with: tr)
            shopping.removeAll { item in
                let n = item.name.lowercased(with: tr)
                return n == key || n.contains(key) || key.contains(n)
            }
        }
    }

    // MARK: Aramalar

    func completeCall(id: String?, person: String?) {
        if let id, calls.contains(where: { $0.id == id }) {
            calls.removeAll { $0.id == id }
        } else if let person {
            let key = person.lowercased(with: Locale(identifier: "tr_TR"))
            calls.removeAll { $0.person.lowercased(with: Locale(identifier: "tr_TR")).contains(key) }
        }
    }
}

// MARK: - Ayarlar

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var serverURL: String { didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") } }
    @Published var userName: String { didSet { UserDefaults.standard.set(userName, forKey: "userName") } }
    @Published var assistantName: String { didSet { UserDefaults.standard.set(assistantName, forKey: "assistantName") } }
    @Published var speakReplies: Bool { didSet { UserDefaults.standard.set(speakReplies, forKey: "speakReplies") } }
    @Published var token: String { didSet { Keychain.set(token, for: "appToken") } }
    /// Uygulama her açıldığında (Siri, ikon, Arkaya Dokunma) kendiliğinden dinlemeye başla
    @Published var autoListen: Bool { didSet { UserDefaults.standard.set(autoListen, forKey: "autoListen") } }
    /// Bilgisayar uygulamasıyla ortak veri (sunucuda JARVIS_KV gerekir)
    @Published var syncEnabled: Bool { didSet { UserDefaults.standard.set(syncEnabled, forKey: "syncEnabled") } }
    /// Doğal (yapay zekâ) ses; kapalıysa iPhone'un kendi sesi
    /// Normal önemdeki hatırlatmalar da alarm gibi çalsın (düşük önem sessiz kalır)
    @Published var alarmAll: Bool { didSet { UserDefaults.standard.set(alarmAll, forKey: "alarmAll") } }
    @Published var naturalVoice: Bool { didSet { UserDefaults.standard.set(naturalVoice, forKey: "naturalVoice") } }
    /// Ses: kadın / erkek ve kalından inceye ton (0 = en kalın, 1 = en ince)
    @Published var voiceFemale: Bool { didSet { UserDefaults.standard.set(voiceFemale, forKey: "voiceFemale") } }
    @Published var voiceTone: Double { didSet { UserDefaults.standard.set(voiceTone, forKey: "voiceTone") } }

    static let maleVoices = ["onyx", "ash", "ballad", "echo", "verse"]      // kalın → ince
    static let femaleVoices = ["sage", "coral", "alloy", "shimmer", "nova"] // kalın → ince

    var voiceName: String {
        let list = voiceFemale ? Self.femaleVoices : Self.maleVoices
        let i = Int((voiceTone * Double(list.count - 1)).rounded())
        return list[max(0, min(list.count - 1, i))]
    }
    @Published var voiceSpeed: Double { didSet { UserDefaults.standard.set(voiceSpeed, forKey: "voiceSpeed") } }

    private init() {
        let d = UserDefaults.standard
        serverURL = d.string(forKey: "serverURL") ?? ""
        userName = d.string(forKey: "userName") ?? "Ertunç"
        assistantName = d.string(forKey: "assistantName") ?? "Jarvis"
        speakReplies = d.object(forKey: "speakReplies") as? Bool ?? true
        autoListen = d.object(forKey: "autoListen") as? Bool ?? true
        alarmAll = d.object(forKey: "alarmAll") as? Bool ?? true
        syncEnabled = d.bool(forKey: "syncEnabled")
        naturalVoice = d.object(forKey: "naturalVoice") as? Bool ?? true
        voiceFemale = d.object(forKey: "voiceFemale") as? Bool ?? false
        voiceTone = d.object(forKey: "voiceTone") as? Double ?? 0
        voiceSpeed = d.object(forKey: "voiceSpeed") as? Double ?? 1.05
        token = Keychain.get("appToken") ?? ""
    }

    var isConfigured: Bool {
        URL(string: serverURL.trimmingCharacters(in: .whitespaces))?.scheme?.hasPrefix("http") == true && !token.isEmpty
    }
}

enum Keychain {
    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
