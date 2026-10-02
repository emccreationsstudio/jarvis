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

    private struct Snapshot: Codable {
        var tasks: [TaskItem]
        var shopping: [ShoppingItem]
        var calls: [CallItem]
        var memory: [MemoryNote]
        var messages: [ChatMessage]
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snap = try? decoder.decode(Snapshot.self, from: data) else { return }
        tasks = snap.tasks
        shopping = snap.shopping
        calls = snap.calls
        memory = snap.memory
        messages = snap.messages
    }

    private func save() {
        guard !loading else { return }
        let snap = Snapshot(tasks: tasks, shopping: shopping, calls: calls, memory: memory, messages: Array(messages.suffix(200)))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snap) {
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
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
    /// Doğal (yapay zekâ) ses; kapalıysa iPhone'un kendi sesi
    @Published var naturalVoice: Bool { didSet { UserDefaults.standard.set(naturalVoice, forKey: "naturalVoice") } }
    @Published var voiceName: String { didSet { UserDefaults.standard.set(voiceName, forKey: "voiceName") } }
    @Published var voiceSpeed: Double { didSet { UserDefaults.standard.set(voiceSpeed, forKey: "voiceSpeed") } }

    private init() {
        let d = UserDefaults.standard
        serverURL = d.string(forKey: "serverURL") ?? ""
        userName = d.string(forKey: "userName") ?? "Ertunç"
        assistantName = d.string(forKey: "assistantName") ?? "Jarvis"
        speakReplies = d.object(forKey: "speakReplies") as? Bool ?? true
        autoListen = d.object(forKey: "autoListen") as? Bool ?? true
        naturalVoice = d.object(forKey: "naturalVoice") as? Bool ?? true
        voiceName = d.string(forKey: "voiceName") ?? "onyx"
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
