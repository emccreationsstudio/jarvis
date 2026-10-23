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
    /// Kullanıcının açtığı listeler (Eczane, Günlük ilaçlar…)
    @Published var lists: [CustomList] = [] { didSet { save() } }
    /// Silinenler — 30 gün geri alınabilir
    @Published var trash: [TrashEntry] = [] { didSet { save() } }

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
        var lists: [CustomList]?
        var trash: [TrashEntry]?
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
                 messages: Array(messages.suffix(300)), specials: specials, moments: moments,
                 lists: lists, trash: trash, updatedAt: updatedAt)
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
        // Eski bilgisayar uygulaması bu alanları göndermez → o zaman buradakini koru
        lists = snap.lists ?? lists
        trash = snap.trash ?? trash
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
        lists = snap.lists ?? []
        trash = snap.trash ?? []
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
        tasks[i].doneAt = Date()
        Reminders.shared.cancel(tasks[i])
        // Eski tamamlanmışları temizle (son 50'yi tut)
        let doneOnes = tasks.filter { $0.done }
        if doneOnes.count > 50 {
            let drop = Set(doneOnes.sorted { $0.createdAt < $1.createdAt }.prefix(doneOnes.count - 50).map(\.id))
            tasks.removeAll { drop.contains($0.id) }
        }
    }

    /// Görevi geri alınabilir şekilde siler (çöp kutusuna)
    func delete(taskID: String) {
        guard let t = task(taskID) else { return }
        Reminders.shared.cancel(t)
        addToTrash(TrashEntry(kind: .task, task: t))
        tasks.removeAll { $0.id == taskID }
    }

    /// İşareti kaldır: görev yeniden açılır, hatırlatması (zamanı geçmediyse) yeniden kurulur
    func reopen(taskID: String) {
        guard let i = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[i].done = false
        tasks[i].doneAt = nil
        Reminders.shared.schedule(tasks[i])
    }

    func toggle(taskID: String) {
        guard let t = task(taskID) else { return }
        if t.done { reopen(taskID: taskID) } else { complete(taskID: taskID) }
    }

    /// Bugün tamamlanan görevler (listede üstü çizili görünür, geri alınabilir)
    var doneToday: [TaskItem] {
        tasks.filter { t in
            guard t.done, let at = t.doneAt else { return false }
            return Calendar.current.isDateInToday(at)
        }
        .sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
    }

    // MARK: Alışveriş

    private static let tr = Locale(identifier: "tr_TR")
    private static func key(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: tr)
    }
    private static func capitalized(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.prefix(1).uppercased(with: tr) + t.dropFirst()
    }
    /// "domates" ↔ "Domates", "süt" ↔ "2 süt" gibi gevşek eşleşme
    private static func loose(_ a: String, _ b: String) -> Bool {
        let x = key(a), y = key(b)
        return x == y || x.contains(y) || y.contains(x)
    }

    var openShopping: [ShoppingItem] { shopping.filter { !$0.done } }

    func addShopping(_ names: [String]) -> [String] {
        var added: [String] = []
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if let i = shopping.firstIndex(where: { Self.key($0.name) == Self.key(name) }) {
                // Daha önce alınmış olarak işaretliyse yeniden aç
                if shopping[i].done { shopping[i].done = false; added.append(name) }
                continue
            }
            shopping.append(ShoppingItem(name: Self.capitalized(name)))
            added.append(name)
        }
        return added
    }

    /// Sesli "aldım": ürünü alındı olarak işaretler (silmez)
    func checkShopping(_ names: [String]) {
        for raw in names {
            for i in shopping.indices where !shopping[i].done && Self.loose(shopping[i].name, raw) {
                shopping[i].done = true
            }
        }
    }

    func toggleShopping(id: String) {
        guard let i = shopping.firstIndex(where: { $0.id == id }) else { return }
        shopping[i].done.toggle()
    }

    func trashShopping(id: String) {
        guard let item = shopping.first(where: { $0.id == id }) else { return }
        addToTrash(TrashEntry(kind: .shopping, shopping: item))
        shopping.removeAll { $0.id == id }
    }

    /// Sesli "listeden çıkar": çöp kutusuna taşır
    func removeShopping(_ names: [String]) {
        let ids = shopping.filter { item in names.contains { Self.loose(item.name, $0) } }.map(\.id)
        ids.forEach { trashShopping(id: $0) }
    }

    /// Alınmış (işaretli) ürünleri temizle → çöp kutusuna
    func clearDoneShopping() {
        shopping.filter(\.done).map(\.id).forEach { trashShopping(id: $0) }
    }

    func clearAllShopping() {
        shopping.map(\.id).forEach { trashShopping(id: $0) }
    }

    // MARK: Aramalar

    var openCalls: [CallItem] { calls.filter { !$0.done } }

    func addCall(person: String, reason: String?) {
        if let i = calls.firstIndex(where: { Self.key($0.person) == Self.key(person) }) {
            calls[i].done = false
            if let reason, !reason.isEmpty { calls[i].reason = reason }
            return
        }
        calls.append(CallItem(person: Self.capitalized(person), reason: reason))
    }

    func toggleCall(id: String) {
        guard let i = calls.firstIndex(where: { $0.id == id }) else { return }
        calls[i].done.toggle()
    }

    func trashCall(id: String) {
        guard let item = calls.first(where: { $0.id == id }) else { return }
        addToTrash(TrashEntry(kind: .call, call: item))
        calls.removeAll { $0.id == id }
    }

    /// Sesli "X'i aradım": arandı olarak işaretler
    func completeCall(id: String?, person: String?) {
        if let id, let i = calls.firstIndex(where: { $0.id == id }) {
            calls[i].done = true
        } else if let person {
            for i in calls.indices where !calls[i].done && Self.loose(calls[i].person, person) {
                calls[i].done = true
            }
        }
    }

    // MARK: Hafıza

    func trashMemory(id: String) {
        guard let note = memory.first(where: { $0.id == id }) else { return }
        addToTrash(TrashEntry(kind: .memory, memory: note))
        memory.removeAll { $0.id == id }
    }

    // MARK: Kullanıcının listeleri

    /// Ada göre listeyi bul ("eczane" → "Eczane", "ilaç listem" → "Günlük ilaçlar" gibi gevşek)
    func list(named name: String?) -> CustomList? {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let k = Self.key(name)
            .replacingOccurrences(of: " listesi", with: "")
            .replacingOccurrences(of: " listem", with: "")
            .replacingOccurrences(of: "listesi", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let exact = lists.first(where: { Self.key($0.name) == k }) { return exact }
        return lists.first { Self.loose($0.name, k) }
    }

    @discardableResult
    func createList(name raw: String, daily: Bool = false) -> CustomList {
        let name = Self.capitalized(raw
            .replacingOccurrences(of: " listesi", with: "")
            .replacingOccurrences(of: " Listesi", with: ""))
        if let existing = list(named: name) {
            if daily, let i = lists.firstIndex(where: { $0.id == existing.id }) { lists[i].daily = true }
            return lists.first { $0.id == existing.id } ?? existing
        }
        let l = CustomList(name: name, icon: CustomList.icon(for: name), daily: daily, lastReset: DateText.dayKey(Date()))
        lists.append(l)
        return l
    }

    func renameList(id: String, to name: String, daily: Bool) {
        guard let i = lists.firstIndex(where: { $0.id == id }) else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { lists[i].name = Self.capitalized(n); lists[i].icon = CustomList.icon(for: n) }
        lists[i].daily = daily
    }

    /// Listeye satır ekler; liste yoksa oluşturur. Eklenenleri döndürür.
    @discardableResult
    func addListItems(_ texts: [String], to listName: String, daily: Bool = false) -> [String] {
        let l = createList(name: listName, daily: daily)
        guard let i = lists.firstIndex(where: { $0.id == l.id }) else { return [] }
        var added: [String] = []
        for raw in texts {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if let j = lists[i].items.firstIndex(where: { Self.key($0.text) == Self.key(t) }) {
                if lists[i].items[j].done { lists[i].items[j].done = false; added.append(t) }
                continue
            }
            lists[i].items.append(ListItem(text: Self.capitalized(t)))
            added.append(t)
        }
        return added
    }

    func toggleListItem(listID: String, itemID: String) {
        guard let i = lists.firstIndex(where: { $0.id == listID }),
              let j = lists[i].items.firstIndex(where: { $0.id == itemID }) else { return }
        lists[i].items[j].done.toggle()
    }

    /// Sesli "ilaçlarımı içtim" → işaretle
    func checkListItems(_ texts: [String], in listName: String?) {
        guard let l = list(named: listName), let i = lists.firstIndex(where: { $0.id == l.id }) else { return }
        // Hiç satır söylenmediyse ("ilaçlarımı içtim") hepsini işaretle
        if texts.isEmpty {
            for j in lists[i].items.indices { lists[i].items[j].done = true }
            return
        }
        for j in lists[i].items.indices where texts.contains(where: { Self.loose(lists[i].items[j].text, $0) }) {
            lists[i].items[j].done = true
        }
    }

    func trashListItem(listID: String, itemID: String) {
        guard let i = lists.firstIndex(where: { $0.id == listID }),
              let item = lists[i].items.first(where: { $0.id == itemID }) else { return }
        addToTrash(TrashEntry(kind: .listItem, listItem: item, listID: listID, listName: lists[i].name))
        lists[i].items.removeAll { $0.id == itemID }
    }

    func removeListItems(_ texts: [String], from listName: String?) {
        guard let l = list(named: listName) else { return }
        let ids = l.items.filter { item in texts.contains { Self.loose(item.text, $0) } }.map(\.id)
        ids.forEach { trashListItem(listID: l.id, itemID: $0) }
    }

    func clearDoneItems(listID: String) {
        guard let l = lists.first(where: { $0.id == listID }) else { return }
        l.items.filter(\.done).forEach { trashListItem(listID: listID, itemID: $0.id) }
    }

    func trashList(id: String) {
        guard let l = lists.first(where: { $0.id == id }) else { return }
        addToTrash(TrashEntry(kind: .list, list: l))
        lists.removeAll { $0.id == id }
    }

    /// Günlük listelerde yeni günde tüm işaretleri kaldır (ör. her sabah ilaçlar yeniden işaretlenmemiş görünür)
    func resetDailyLists() {
        let today = DateText.dayKey(Date())
        guard lists.contains(where: { $0.daily && $0.lastReset != today }) else { return }
        var copy = lists
        for i in copy.indices where copy[i].daily && copy[i].lastReset != today {
            for j in copy[i].items.indices { copy[i].items[j].done = false }
            copy[i].lastReset = today
        }
        lists = copy
    }

    // MARK: Çöp kutusu (30 gün)

    private func addToTrash(_ entry: TrashEntry) {
        var t = trash
        t.insert(entry, at: 0)
        let limit = Date().addingTimeInterval(-30 * 86400)
        t.removeAll { $0.deletedAt < limit }
        if t.count > 300 { t = Array(t.prefix(300)) }
        trash = t
    }

    func restore(_ entry: TrashEntry) {
        switch entry.kind {
        case .task:
            if let t = entry.task, !tasks.contains(where: { $0.id == t.id }) {
                tasks.append(t)
                Reminders.shared.schedule(t)
            }
        case .shopping:
            if let s = entry.shopping, !shopping.contains(where: { $0.id == s.id }) { shopping.append(s) }
        case .call:
            if let c = entry.call, !calls.contains(where: { $0.id == c.id }) { calls.append(c) }
        case .memory:
            if let m = entry.memory, !memory.contains(where: { $0.id == m.id }) { memory.append(m) }
        case .listItem:
            guard let item = entry.listItem else { break }
            if let i = lists.firstIndex(where: { $0.id == entry.listID }) {
                if !lists[i].items.contains(where: { $0.id == item.id }) { lists[i].items.append(item) }
            } else {
                // Liste de silinmişse aynı adla yeniden aç
                var l = CustomList(name: entry.listName ?? "Liste")
                if let id = entry.listID { l.id = id }
                l.icon = CustomList.icon(for: l.name)
                l.items = [item]
                lists.append(l)
            }
        case .list:
            if let l = entry.list, !lists.contains(where: { $0.id == l.id }) { lists.append(l) }
        }
        trash.removeAll { $0.id == entry.id }
    }

    func purge(_ entry: TrashEntry) {
        trash.removeAll { $0.id == entry.id }
    }

    func emptyTrash() {
        trash.removeAll()
    }

    /// Uygulama açılışında: süresi dolanları at, günlük listeleri sıfırla
    func housekeeping() {
        let limit = Date().addingTimeInterval(-30 * 86400)
        if trash.contains(where: { $0.deletedAt < limit }) { trash.removeAll { $0.deletedAt < limit } }
        resetDailyLists()
        clearYesterdaysDone()
    }

    /// 1.2.5: Üstü çizilen (tamamlanan) görevler ertesi gün kendiliğinden çöp kutusuna gider.
    /// Gün içinde işaret kaldırılırsa görev kalır.
    func clearYesterdaysDone() {
        let start = Calendar.current.startOfDay(for: Date())
        let old = tasks.filter { $0.done && ($0.doneAt ?? $0.createdAt) < start }
        guard !old.isEmpty else { return }
        var t = trash
        for task in old { t.insert(TrashEntry(kind: .task, task: task), at: 0) }
        if t.count > 300 { t = Array(t.prefix(300)) }
        trash = t
        let ids = Set(old.map(\.id))
        tasks.removeAll { ids.contains($0.id) }
    }
}

// MARK: - Dayanıklı okuma

/// Bozuk tek bir kayıt (ör. eski bilgisayar sürümünden) tüm verinin okunmasını engellemesin
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension Store.Snapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try c.decode([TaskItem].self, forKey: .tasks)
        shopping = try c.decode([ShoppingItem].self, forKey: .shopping)
        calls = try c.decode([CallItem].self, forKey: .calls)
        memory = try c.decode([MemoryNote].self, forKey: .memory)
        messages = try c.decode([ChatMessage].self, forKey: .messages)
        specials = try c.decodeIfPresent([SpecialDay].self, forKey: .specials)
        moments = try c.decodeIfPresent([Moment].self, forKey: .moments)
        lists = (try? c.decodeIfPresent([Lossy<CustomList>].self, forKey: .lists))?.compactMap { $0.value }
        trash = (try? c.decodeIfPresent([Lossy<TrashEntry>].self, forKey: .trash))?.compactMap { $0.value }
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
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
    /// Apple sunucusunda konuşma tanıma (Türkçede daha doğru); kapalıysa cihaz üzerinde
    @Published var cloudRecognition: Bool { didSet { UserDefaults.standard.set(cloudRecognition, forKey: "cloudRecognition") } }
    /// Sabah özeti: her gün bu saatte bildirim gelir, dokununca Jarvis hava, takvim ve haberleri okur
    @Published var morningBrief: Bool { didSet { UserDefaults.standard.set(morningBrief, forKey: "morningBrief"); Reminders.shared.scheduleMorningBrief() } }
    @Published var morningBriefMinutes: Int { didSet { UserDefaults.standard.set(morningBriefMinutes, forKey: "morningBriefMinutes"); Reminders.shared.scheduleMorningBrief() } }
    /// Yol tarifinde açılacak harita: apple · google · yandex
    @Published var mapsApp: String { didSet { UserDefaults.standard.set(mapsApp, forKey: "mapsApp") } }

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
        cloudRecognition = d.object(forKey: "cloudRecognition") as? Bool ?? true
        morningBrief = d.object(forKey: "morningBrief") as? Bool ?? false
        morningBriefMinutes = d.object(forKey: "morningBriefMinutes") as? Int ?? 8 * 60
        mapsApp = d.string(forKey: "mapsApp") ?? "apple"
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
