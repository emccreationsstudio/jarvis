import Foundation
import SwiftUI
import Combine

/// Dinle → sunucuya sor → işlemleri telefonda uygula → sesli cevap ver.
@MainActor
final class Assistant: ObservableObject {
    static let shared = Assistant()

    enum Phase: Equatable { case idle, listening, thinking, speaking }

    @Published var phase: Phase = .idle
    @Published var lastRoute: RouteService.Result?
    @Published var errorText: String?
    /// Siri / Kısayol / Arkaya Dokunma ile açılınca dinlemeye başla
    @Published var listenRequested = false

    let speech = SpeechService()
    private let store = Store.shared
    private let settings = AppSettings.shared
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Konuşma durumundaki değişiklikler (canlı yazı, ses seviyesi) ekranı da güncellesin
        speech.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: Dinleme

    func toggleListening() {
        switch phase {
        case .listening:
            speech.stopListening()
        case .speaking:
            speech.stopSpeaking()
            phase = .idle
        case .thinking:
            break
        case .idle:
            startListening()
        }
    }

    func startListening() {
        errorText = nil
        Task {
            guard await speech.requestPermissions() else {
                errorText = "Mikrofon ve konuşma tanıma izni gerekiyor. Ayarlar → Jarvis'ten açabilirsiniz."
                return
            }
            phase = .listening
            speech.startListening { [weak self] text in
                guard let self else { return }
                self.phase = .idle
                if !text.isEmpty { self.send(text) }
            }
        }
    }

    // MARK: Gönder

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        errorText = nil
        lastRoute = nil
        store.messages.append(ChatMessage(role: .user, text: text))

        guard settings.isConfigured else {
            reply("Önce Ayarlar'dan sunucu adresini ve uygulama şifresini girmen gerekiyor.", speak: true)
            return
        }

        phase = .thinking
        Task {
            do {
                let response = try await request(text)
                var extras: [String] = []
                for action in response.actions {
                    if let note = await apply(action) { extras.append(note) }
                }
                let full = ([response.reply] + extras).filter { !$0.isEmpty }.joined(separator: " ")
                reply(full, speak: settings.speakReplies)
            } catch {
                phase = .idle
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                reply("Şu anda sunucuya ulaşamıyorum. İnternet bağlantını ya da Ayarlar'daki sunucu bilgisini kontrol eder misin?", speak: settings.speakReplies)
            }
        }
    }

    private func reply(_ text: String, speak: Bool) {
        store.messages.append(ChatMessage(role: .assistant, text: text))
        if speak {
            phase = .speaking
            speech.speak(text) { [weak self] in
                if self?.phase == .speaking { self?.phase = .idle }
            }
        } else {
            phase = .idle
        }
    }

    // MARK: Sunucu

    struct ServerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func request(_ text: String) async throws -> ChatResponse {
        let base = settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat") else { throw ServerError(message: "Sunucu adresi geçersiz.") }

        let history = store.messages.dropLast().suffix(12).map { ChatRequest.HistoryItem(role: $0.role.rawValue, content: $0.text) }
        let body = ChatRequest(message: text, history: Array(history), context: context())

        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 401 { throw ServerError(message: "Uygulama şifresi sunucudakiyle eşleşmiyor.") }
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "Sunucu hatası (\(status))"
            throw ServerError(message: msg)
        }
        return try JSONDecoder().decode(ChatResponse.self, from: data)
    }

    func testConnection() async -> String {
        guard settings.isConfigured else { return "Sunucu adresi ve şifre girilmemiş." }
        do {
            let r = try await request("Bağlantı testi. Sadece 'Bağlantı tamam' de, hiçbir işlem yapma.")
            return "Bağlantı başarılı: \(r.reply)"
        } catch {
            return "Bağlantı kurulamadı: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private func context() -> ChatRequest.Context {
        let wire = DateText.wire
        let events = CalendarService.shared.upcoming(days: 3).map {
            ChatRequest.Context.E(start: wire.string(from: $0.start), end: $0.end.map { wire.string(from: $0) }, title: $0.title, location: $0.location)
        }
        return ChatRequest.Context(
            now: DateText.now.string(from: Date()),
            timezone: TimeZone.current.identifier,
            userName: settings.userName,
            assistantName: settings.assistantName,
            tasks: store.openTasks.prefix(60).map { .init(id: $0.id, title: $0.title, due: $0.due.map { wire.string(from: $0) }, priority: $0.priority.rawValue) },
            shopping: store.shopping.map { .init(id: $0.id, name: $0.name) },
            calls: store.calls.map { .init(id: $0.id, person: $0.person, reason: $0.reason) },
            events: events,
            memory: store.memory.suffix(80).map { .init(id: $0.id, text: $0.text) }
        )
    }

    // MARK: İşlemler

    /// İşlemi uygular; söylenmesi gereken ek bir bilgi varsa döndürür.
    private func apply(_ a: AssistantAction) async -> String? {
        let priority = a.priority.flatMap(Priority.init(rawValue:))
        switch a.type {
        case "add_task":
            guard let title = a.title, !title.isEmpty else { return nil }
            let task = TaskItem(title: title, due: DateText.parse(a.due), priority: priority ?? .normal)
            store.upsert(task)
            if task.due != nil { await Reminders.shared.requestPermission() }
            return nil

        case "update_task":
            guard var t = store.task(a.target_id) else { return nil }
            if let title = a.title, !title.isEmpty { t.title = title }
            if let due = DateText.parse(a.due) { t.due = due }
            if let priority { t.priority = priority }
            store.upsert(t)
            return nil

        case "complete_task":
            if let id = a.target_id { store.complete(taskID: id) }
            return nil

        case "delete_task":
            if let id = a.target_id { store.delete(taskID: id) }
            return nil

        case "add_shopping":
            let items = a.items ?? []
            _ = store.addShopping(items.isEmpty ? [a.title].compactMap { $0 } : items)
            return nil

        case "remove_shopping":
            store.removeShopping(a.items ?? [a.title].compactMap { $0 })
            return nil

        case "clear_shopping":
            store.shopping.removeAll()
            return nil

        case "add_call":
            guard let person = a.person ?? a.title, !person.isEmpty else { return nil }
            store.calls.append(CallItem(person: person, reason: a.person == nil ? nil : a.title))
            return nil

        case "complete_call":
            store.completeCall(id: a.target_id, person: a.person)
            return nil

        case "add_event":
            guard let title = a.title, let start = DateText.parse(a.due) else { return nil }
            let ok = await CalendarService.shared.add(title: title, start: start, end: DateText.parse(a.end), location: a.location, important: priority == .high || priority == .critical)
            if !ok {
                store.upsert(TaskItem(title: title, due: start, priority: priority ?? .high))
                return "Takvime erişim iznim olmadığı için bunu görev olarak ekledim."
            }
            return nil

        case "get_route":
            guard let dest = a.destination, !dest.isEmpty else { return nil }
            if let r = await RouteService.shared.route(from: a.origin, to: dest) {
                lastRoute = r
                return r.summary
            }
            return "Rotayı hesaplayamadım. Konum izni açık mı ve adres doğru mu kontrol eder misin?"

        case "remember":
            guard let note = a.note ?? a.title, !note.isEmpty else { return nil }
            store.memory.append(MemoryNote(text: note))
            return nil

        case "forget":
            if let id = a.target_id { store.memory.removeAll { $0.id == id } }
            return nil

        default:
            return nil
        }
    }

    // MARK: İlk açılış izinleri

    func requestAllPermissions() async {
        _ = await speech.requestPermissions()
        await Reminders.shared.requestPermission()
        await CalendarService.shared.requestAccess()
        await RouteService.shared.requestPermission()
        _ = await Reminders.shared.requestAlarmPermission()
    }
}
