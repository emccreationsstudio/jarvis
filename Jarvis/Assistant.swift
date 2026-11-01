import Foundation
import SwiftUI
import Combine
import UIKit

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
    /// 1.2.7: gönderilmeyi bekleyen ekler (fotoğraf, belge, konum, kişi)
    @Published var pending: [Attachment] = []
    /// Jarvis "takvimi göster" dediğinde açılacak sayfa
    @Published var calendarRequest: CalendarPage?
    /// Sabah özeti bildirimine dokunuldu → açılınca özeti oku
    @Published var briefRequested = false
    static let briefPrompt = "Günün özetini ver: hava durumu, bugünkü programım (takvim ve hatırlatmalar), trafik, bu haftanın önemli işleri (önümüzdeki 7 gün, en fazla 3 tane, gün adıyla), piyasa (dolar, euro, gram altın, gümüş: bugünkü fiyat ve dünden bu yana arttı mı azaldı mı, yüzdesiyle), ve haberler: sayı sınırı yok, Türkiye ve dünyadan gerçekten önemli olanları seç, sıradan olayları atla, her birini bir cümleyle anlat. Sesli okunacak; akıcı anlat, madde işareti kullanma."

    let speech = SpeechService()
    private let store = Store.shared
    private let settings = AppSettings.shared
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // 1.2.9: Siri / Kısayollar "Jarvis'i Dinlet" → uygulama açıksa hemen dinle
        NotificationCenter.default.addObserver(forName: .jarvisListenRequest, object: nil, queue: .main) { _ in
            Task { @MainActor in Assistant.shared.listenRequested = true }
        }
        // Konuşma durumundaki değişiklikler (canlı yazı, ses seviyesi) ekranı da güncellesin
        speech.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Yeniden konuşmaya başlanınca bekleyen gönderimi ertele
        speech.$partialText
            .removeDuplicates()
            .sink { [weak self] text in
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                Task { @MainActor in self?.userIsSpeaking() }
            }
            .store(in: &cancellables)
    }

    // MARK: Sohbet modu
    //
    // "Hey Siri, Jarvis" ya da reaktöre dokunuş → sürekli dinler, sözünü kesmez.
    // Söylenenler not olarak birikir; "bitti" → hepsini işler; "Jarvis kapan" → işler ve kapanır.
    // Soru sorulursa hemen sesli cevap verir, sonra dinlemeye devam eder.

    /// Sohbet açık mı (mikrofon o an kapalı olsa bile: düşünürken/konuşurken)
    @Published private(set) var conversing = false
    /// Söylenmiş ama "bitti" denmediği için henüz işlenmemiş cümleler
    @Published private(set) var pendingNotes: [String] = []

    private var closeAfterReply = false
    private var idleTask: Task<Void, Never>?
    private let idleLimit: UInt64 = 120   // sn — hiç konuşulmazsa kapanır

    /// Reaktöre dokunuş
    func toggleListening() {
        if !conversing {
            startConversation()
            return
        }
        switch phase {
        case .speaking:
            speech.stopSpeaking()          // susturur; akış dinlemeye döner
        case .thinking:
            break
        case .listening, .idle:
            // Dokununca: yarım cümleyi de al, bekleyenleri işle ve kapan
            let partial = speech.partialText.trimmingCharacters(in: .whitespacesAndNewlines)
            speech.stopMic()
            if !partial.isEmpty { pendingNotes.append(VoiceCommand.parse(NumberWords.normalize(partial)).body) }
            finish(close: true)
        }
    }

    /// Siri / Kısayol / ekrandan
    func startListening() { if !conversing { startConversation(greet: true) } }

    /// Ekranda gösterilen sohbetin başlangıcı: bugünün başı.
    /// Gün içinde konuşulanlar ekranda kalır, her yeni günde sayfa temiz açılır (eski konuşmalar saklanır).
    @Published private(set) var sessionStart = Calendar.current.startOfDay(for: Date())

    /// Uygulama ön plana geldi (Siri, ikon, Arkaya Dokunma…)
    private var activeSince = Date()

    /// Yazı alanının yanındaki mikrofon: dinlemiyorsa başlat, dinliyorsa mikrofonu sıfırdan kur
    func micButton() {
        if !conversing { startConversation(); return }
        if phase == .speaking { speech.stopSpeaking(); return }
        speech.stopMic()
        openMic()
    }

    func appBecameActive() {
        activeSince = Date()
        // Siri isteği uygulama kapalıyken geldiyse (son 20 sn) dinlemeye başla
        let siriAt = UserDefaults.standard.double(forKey: "siriListenAt")
        if siriAt > 0, Date().timeIntervalSince1970 - siriAt < 20 {
            UserDefaults.standard.removeObject(forKey: "siriListenAt")
            listenRequested = true
        }
        Task { await SyncService.shared.pull() }   // eşitleme açıksa bilgisayardaki değişiklikleri al
        sessionStart = Calendar.current.startOfDay(for: Date())
        store.housekeeping()                       // günlük listeleri sıfırla, eski çöpü at
        RouteService.shared.refreshLocation()      // hava durumu için yaklaşık konum
        lastRoute = nil
        errorText = nil
        // 1.2.8: günün ilk açılışında (05:00'ten sonra) kendiliğinden günün özeti; gün içindeki diğer açılışlarda değil
        let today = DateText.dayKey(Date())
        let firstToday = settings.autoBrief && Calendar.current.component(.hour, from: Date()) >= 5
            && UserDefaults.standard.string(forKey: "autoBriefDay") != today
        if briefRequested || firstToday {
            briefRequested = false
            listenRequested = false
            guard UserDefaults.standard.bool(forKey: "didOnboard") else { return }
            UserDefaults.standard.set(today, forKey: "autoBriefDay")
            if conversing { endConversation() }
            Task { @MainActor in
                async let trafficTask = self.trafficLine()
                async let marketTask = Self.marketLine()
                let (traffic, market) = await (trafficTask, marketTask)
                var prompt = Self.briefPrompt
                if let traffic { prompt += "\nTRAFİK: " + traffic }
                prompt += "\nPİYASA: " + (market ?? "Piyasa verisi alınamadı; bunu kısaca söyle, fiyat uydurma.")
                self.send(prompt, voice: true, display: "Günün özeti")
            }
            return
        }
        let wanted = listenRequested || settings.autoListen
        listenRequested = false
        guard wanted, UserDefaults.standard.bool(forKey: "didOnboard"), !conversing, phase == .idle else { return }
        startConversation(greet: true)
    }

    /// Yazı alanına dokunuldu → dinlemeyi durdur (söylenmiş notlar kaybolmasın)
    func pauseForTyping() {
        guard conversing else { return }
        if phase == .speaking { speech.stopSpeaking() }
        if pendingNotes.isEmpty {
            endConversation()
        } else {
            finish(close: true)
        }
    }

    /// 1.2.5: "Dinlemeyi bırak" düğmesi — mikrofon kapanır, uygulama açık kalır, yazarak devam edilir.
    /// Söylenmiş ama işlenmemiş cümle varsa kaybolmaz, işlenir.
    func stopListeningButton() {
        let partial = speech.partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        speech.stopMic()
        if !partial.isEmpty { pendingNotes.append(VoiceCommand.parse(NumberWords.normalize(partial)).body) }
        if conversing {
            // önce sohbeti kapat ki "Efendim?" bitince mikrofon yeniden açılmasın
            if pendingNotes.isEmpty { endConversation() } else { finish(close: true) }
        }
        if phase == .speaking && pendingNotes.isEmpty { speech.stopSpeaking() }
        if phase == .listening || (phase == .speaking && !speech.isSpeaking) { phase = .idle }
    }

    /// Uygulama arka plana gitti → mikrofonu bırak
    func appWentBackground() {
        guard conversing else { return }
        if pendingNotes.isEmpty {
            speech.stopSpeaking()
            endConversation()
        } else {
            finish(close: true)            // söylenenler kaybolmasın
        }
    }

    private var starting = false

    func startConversation(greet: Bool = false) {
        guard !conversing, !starting else { return }
        starting = true
        errorText = nil
        Task {
            defer { starting = false }
            guard await speech.requestPermissions() else {
                errorText = "Mikrofon ve konuşma tanıma izni gerekiyor. Ayarlar → Jarvis'ten açabilirsiniz."
                return
            }
            speech.stopSpeaking()
            // Siri ile açıldıysa Siri mikrofonu bir an daha tutuyor; hemen başlarsak boş ses geliyordu
            if UIApplication.shared.applicationState != .active || Date().timeIntervalSince(activeSince) < 1.5 {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
            conversing = true
            closeAfterReply = false
            pendingNotes = []
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if greet {
                phase = .speaking
                speech.speak("Efendim?") { [weak self] in self?.openMic() }
                // Ses çıkmazsa (ör. Siri sesi hâlâ tutuyorsa) yine de dinlemeye geç
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    guard let self, self.conversing, !self.speech.isListening,
                          self.phase == .speaking, !self.speech.isSpeaking else { return }
                    self.speech.stopSpeaking()
                    self.openMic()
                }
            } else {
                openMic()
            }
        }
    }

    func endConversation() {
        idleTask?.cancel()
        commitTask?.cancel()
        speech.stopMic()
        conversing = false
        closeAfterReply = false
        if phase != .thinking && phase != .speaking { phase = .idle }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func openMic(attempt: Int = 0) {
        guard conversing else { return }
        if speech.isListening { phase = .listening; return }
        phase = .listening
        speech.vocabulary = vocabulary()
        let ok = speech.startMic { [weak self] segment in
            self?.handleSegment(segment)
        }
        if !ok {
            // Uygulama yeni açıldıysa ses sistemi (Siri) birkaç an meşgul olabilir → tekrar dene
            if attempt < 5 {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    self?.openMic(attempt: attempt + 1)
                }
            } else {
                errorText = "Mikrofon başlatılamadı. Reaktöre dokunup tekrar deneyin."
                endConversation()
            }
            return
        }
        errorText = nil
        armIdleTimer()
    }

    private func armIdleTimer() {
        idleTask?.cancel()
        let limit = idleLimit
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: limit * 1_000_000_000)
            guard !Task.isCancelled, let self, self.conversing, self.phase == .listening else { return }
            self.finish(close: true)
        }
    }

    // Akış:
    //  • Her cümle not olarak birikir.
    //  • Kısa bir sessizlikten sonra (komut/soru ise daha kısa) hepsi birlikte gönderilir — "bitti" demek gerekmez.
    //  • Bu arada konuşmaya devam edilirse bekler, yeni söylenenleri de ekler.
    //  • Jarvis düşünürken araya girilirse istek iptal edilir; eski + yeni söylenenler birlikte yeniden düşünülür.

    private var commitTask: Task<Void, Never>?
    private var inflight: Task<Void, Never>?
    private var inflightText: String?
    private var inflightMessageID: String?
    private var inflightAttachments: [Attachment] = []

    private func handleSegment(_ segment: String) {
        guard conversing else { return }
        armIdleTimer()
        // Söylenen sayılar rakamla: "saat dörtte iki domates" → "saat 4'te 2 domates"
        let parsed = VoiceCommand.parse(NumberWords.normalize(segment))

        // Düşünürken araya girildi → isteği iptal et, söyleneni geri al ve birleştir
        if let prev = inflightText, phase == .thinking {
            inflight?.cancel()
            inflight = nil
            inflightText = nil
            if let id = inflightMessageID { store.messages.removeAll { $0.id == id } }
            inflightMessageID = nil
            pendingNotes.insert(prev, at: 0)
            if !inflightAttachments.isEmpty { pending = inflightAttachments + pending; inflightAttachments = [] }
            phase = .listening
        }

        switch parsed.end {
        case .close:
            if !parsed.body.isEmpty { pendingNotes.append(parsed.body) }
            finish(close: true)
        case .done:
            if !parsed.body.isEmpty { pendingNotes.append(parsed.body) }
            finish(close: false)
        case .none:
            guard !parsed.body.isEmpty else { return }
            pendingNotes.append(parsed.body)
            UISelectionFeedbackGenerator().selectionChanged()
            scheduleCommit(quick: VoiceCommand.isComplete(parsed.body))
        }
    }

    /// Kısa bekleyip gönder. Bu sürede yeniden konuşulursa iptal edilir.
    private func scheduleCommit(quick: Bool) {
        commitTask?.cancel()
        let delay: UInt64 = quick ? 700_000_000 : 1_800_000_000
        commitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, self.conversing else { return }
            guard self.speech.partialText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            self.finish(close: false)
        }
    }

    /// Kullanıcı yeniden konuşmaya başladı → bekleyen gönderimi ertele
    private func userIsSpeaking() {
        commitTask?.cancel()
        commitTask = nil
    }

    /// Bekleyen notları işle. close: sonra sohbeti kapat.
    private func finish(close: Bool) {
        commitTask?.cancel()
        commitTask = nil
        let text = pendingNotes.joined(separator: " ")
        pendingNotes = []
        if text.isEmpty {
            if close {
                speech.stopMic()
                conversing = false
                phase = .speaking
                speech.speak("Kapanıyorum.") { [weak self] in self?.phase = .idle }
            }
            return
        }
        closeAfterReply = close
        send(text, voice: true)
    }

    // MARK: Gönder

    /// 1.2.8: dolar, euro, gram altın, gümüş — bugünkü fiyat ve günlük değişim (finans.truncgil.com)
    static func marketLine() async -> String? {
        guard let url = URL(string: "https://finans.truncgil.com/today.json") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Mozilla/5.0 JarvisMobile", forHTTPHeaderField: "User-Agent")
        guard let result = try? await URLSession.shared.data(for: req),
              let obj = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any] else { return nil }
        let wanted: [(String, String)] = [("USD", "Dolar"), ("EUR", "Euro"), ("gram-altin", "Gram altın"),
                                          ("ceyrek-altin", "Çeyrek altın"), ("gumus", "Gümüş (gram)")]
        var parts: [String] = []
        for (key, label) in wanted {
            guard let row = obj[key] as? [String: Any] else { continue }
            let price = (row["Satış"] ?? row["Satis"] ?? row["Alış"]).map { "\($0)" } ?? "?"
            let change = (row["Değişim"] ?? row["Degisim"]).map { "\($0)" } ?? ""
            parts.append("\(label) \(price) TL" + (change.isEmpty ? "" : " (değişim \(change))"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// Bugün yeri belli olan ilk (henüz başlamamış) randevuya canlı trafikle gidiş süresi (Apple Haritalar)
    /// 1.3.1: randevu olmasa da sık gidilen yerlere canlı süreler (Apple Haritalar) verilir.
    private func trafficLine() async -> String? {
        let now = Date()
        var parts: [String] = []
        if let ev = CalendarService.shared.upcoming(days: 1).first(where: {
            $0.start > now && !($0.location ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }), let loc = ev.location {
            let time = ev.start.formatted(date: .omitted, time: .shortened)
            if let r = await RouteService.shared.route(from: nil, to: loc) {
                parts.append("\(time) \(ev.title) randevusu için: \(r.summary). Ne zaman çıkması gerektiğini öner.")
            } else {
                parts.append("\(time) \(ev.title) (\(loc)) için yol süresi hesaplanamadı.")
            }
        }
        if let general = await RouteService.shared.generalTraffic() {
            parts.append("Genel yoğunluk (canlı, Apple Haritalar): " + general)
        }
        if parts.isEmpty {
            return "Trafik verisi alınamadı (konum izni ya da internet olabilir); bunu kısaca söyle, tahmin uydurma."
        }
        return parts.joined(separator: " ")
    }

    /// "Trafik nasıl", "yollar nasıl" gibi genel sorular — canlı veriyi telefon hesaplayıp mesaja ekler.
    static func isTrafficQuestion(_ text: String) -> Bool {
        let t = text.lowercased(with: Locale(identifier: "tr_TR"))
        return ["trafik", "yollar nasıl", "yol durumu", "yollar açık", "yollar kapalı", "yoğunluk"].contains { t.contains($0) }
    }

    func send(_ raw: String, voice: Bool = false, display: String? = nil) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pending
        guard !text.isEmpty || !attachments.isEmpty else { return }
        pending = []
        if text.isEmpty {
            text = attachments.contains { $0.kind == .location } && attachments.count == 1
                ? "Konumumu paylaşıyorum." : "Bunu incele ve kısaca ne olduğunu söyle."
        }
        let images = Array(attachments.flatMap(\.images).prefix(3))
        let docText = attachments.compactMap(\.text).joined(separator: "\n\n")
        errorText = nil
        lastRoute = nil
        inflight?.cancel()
        let shownText = display ?? text
        let shown = attachments.isEmpty ? shownText
            : attachments.map { "📎 \($0.label)" }.joined(separator: "\n") + "\n" + shownText
        let message = ChatMessage(role: .user, text: shown)
        store.messages.append(message)
        if conversing { idleTask?.cancel() }   // mikrofon açık kalır: araya girilebilir

        guard settings.isConfigured else {
            reply("Önce Ayarlar'dan sunucu adresini ve uygulama şifresini girmen gerekiyor.", speak: true)
            return
        }

        phase = .thinking
        inflightText = text
        inflightMessageID = message.id
        inflightAttachments = attachments
        inflight = Task { [weak self] in
            guard let self else { return }
            do {
                var outgoing = text
                if display == nil, Self.isTrafficQuestion(text), let live = await RouteService.shared.generalTraffic() {
                    outgoing += "\n\n[CANLI TRAFİK VERİSİ — telefon Apple Haritalar'dan şimdi hesapladı; web araması yapma, bunu kullan. "
                        + "Belirli bir yer sorulduysa get_route da kullanabilirsin.]\n" + live
                }
                guard !Task.isCancelled else { return }
                let response = try await self.request(outgoing, voice: voice,
                                                      images: images.isEmpty ? nil : images,
                                                      document: docText.isEmpty ? nil : docText)
                guard !Task.isCancelled else { return }
                self.inflightText = nil
                self.inflightMessageID = nil
                var extras: [String] = []
                for action in response.actions {
                    if let note = await self.apply(action) { extras.append(note) }
                }
                let full = ([response.reply] + extras).filter { !$0.isEmpty }.joined(separator: " ")
                self.reply(full, speak: self.conversing || self.settings.speakReplies)
            } catch {
                guard !Task.isCancelled else { return }
                self.inflightText = nil
                self.inflightMessageID = nil
                self.errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.reply("Şu anda sunucuya ulaşamıyorum. İnternet bağlantını ya da Ayarlar'daki sunucu bilgisini kontrol eder misin?", speak: self.conversing || self.settings.speakReplies)
            }
        }
    }

    private func reply(_ text: String, speak: Bool) {
        store.messages.append(ChatMessage(role: .assistant, text: text))
        if speak {
            if conversing { speech.stopMic() }   // Jarvis konuşurken kendini duymasın
            phase = .speaking
            // "Jarvis kapan" denmişse uzun cevap okunmaz; yalnızca "Kapanıyorum" der (cevap ekranda kalır)
            speech.speak(closeAfterReply ? "Kapanıyorum." : text) { [weak self] in self?.afterReply() }
        } else {
            afterReply()
        }
    }

    /// Cevap bitti: sohbet sürüyorsa yeniden dinle, "kapan" denmişse kapat.
    private func afterReply() {
        if conversing && !closeAfterReply {
            openMic()
        } else {
            if conversing { endConversation() }
            closeAfterReply = false
            phase = .idle
        }
    }

    // MARK: Sunucu

    struct ServerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func request(_ text: String, voice: Bool = false, images: [String]? = nil,
                         document: String? = nil) async throws -> ChatResponse {
        let base = settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat") else { throw ServerError(message: "Sunucu adresi geçersiz.") }

        // Yalnızca bugünün konuşması (her gün temiz sayfa; kalıcı bilgiler hafızada)
        let today = Calendar.current.startOfDay(for: Date())
        let history = store.messages.dropLast().filter { $0.date >= today }.suffix(12)
            .map { ChatRequest.HistoryItem(role: $0.role.rawValue, content: $0.text) }
        var body = ChatRequest(message: text, history: Array(history), context: context(), voice: voice)
        body.images = images
        body.document = document

        var req = URLRequest(url: url, timeoutInterval: images == nil ? 60 : 120)
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
        let events = CalendarService.shared.upcoming(days: 7).map {
            ChatRequest.Context.E(id: $0.id, start: wire.string(from: $0.start), end: $0.end.map { wire.string(from: $0) }, title: $0.title, location: $0.location)
        }
        let loc = RouteService.shared.approximateCoordinate().map { ChatRequest.Context.Loc(lat: $0.lat, lon: $0.lon) }
        return ChatRequest.Context(
            now: DateText.now.string(from: Date()),
            timezone: TimeZone.current.identifier,
            userName: settings.userName,
            assistantName: settings.assistantName,
            tasks: store.openTasks.prefix(60).map { .init(id: $0.id, title: $0.title, due: $0.due.map { wire.string(from: $0) }, priority: $0.priority.rawValue) },
            shopping: store.openShopping.map { .init(id: $0.id, name: $0.name) },
            calls: store.openCalls.map { .init(id: $0.id, person: $0.person, reason: $0.reason) },
            events: events,
            memory: store.memory.suffix(80).map { .init(id: $0.id, text: $0.text) },
            specials: store.specials.map { d in
                let next = d.next()
                return ChatRequest.Context.SD(id: d.id, title: d.title, person: d.person, kind: d.kind.label,
                                              next: DateText.dayKey(next), years: d.years(on: next))
            },
            holidays: Holiday.between(Date(), Date().addingTimeInterval(60 * 86400))
                .filter { !$0.title.contains(". gün") || $0.title.hasSuffix("1. gün") }
                .map { ChatRequest.Context.H(date: DateText.dayKey($0.date), title: $0.title) },
            moments: store.moments.prefix(20).map {
                ChatRequest.Context.MO(date: DateText.dayKey($0.date), title: $0.title, place: $0.place, note: $0.note)
            },
            lists: store.lists.map { l in
                ChatRequest.Context.L(id: l.id, name: l.name, daily: l.daily,
                                      items: l.items.filter { !$0.done }.map(\.text),
                                      done: l.items.filter(\.done).map(\.text))
            },
            location: loc
        )
    }

    /// Konuşma tanımaya ipucu: sık geçen özel adlar
    private func vocabulary() -> [String] {
        var words = [settings.assistantName, "Jarvis", settings.userName, "Kapanıyorum", "Zoom", "Ses Açma"]
        words += store.lists.map(\.name)
        words += store.calls.map(\.person)
        words += store.shopping.suffix(30).map(\.name)
        words += store.lists.flatMap { $0.items.prefix(10).map(\.text) }
        var seen = Set<String>()
        return words.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
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

        case "check_shopping":
            store.checkShopping(Self.items(a))
            return nil

        case "remove_shopping":
            store.removeShopping(Self.items(a))
            return nil

        case "clear_shopping":
            store.clearAllShopping()
            return nil

        case "add_call":
            guard let person = a.person ?? a.title, !person.isEmpty else { return nil }
            store.addCall(person: person, reason: a.person == nil ? nil : a.title)
            return nil

        case "reopen_task":
            if let id = a.target_id { store.reopen(taskID: id) }
            return nil

        // Kullanıcının listeleri (Eczane, Günlük ilaçlar…)
        case "create_list":
            guard let name = a.title, !name.isEmpty else { return nil }
            store.createList(name: name, daily: Self.isDaily(a.note))
            if let items = a.items, !items.isEmpty { store.addListItems(items, to: name) }
            return nil

        case "add_list_items":
            guard let name = a.title, !name.isEmpty else { return nil }
            store.addListItems(a.items ?? [], to: name, daily: Self.isDaily(a.note))
            return nil

        case "check_list_items":
            store.checkListItems(a.items ?? [], in: a.title)
            return nil

        case "remove_list_items":
            store.removeListItems(a.items ?? [], from: a.title)
            return nil

        case "delete_list":
            if let id = a.target_id, store.lists.contains(where: { $0.id == id }) {
                store.trashList(id: id)
            } else if let l = store.list(named: a.title) {
                store.trashList(id: l.id)
            }
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

        case "update_event":
            guard let id = a.target_id else { return nil }
            let ok = await CalendarService.shared.update(id: id, title: a.title, start: DateText.parse(a.due),
                                                          end: DateText.parse(a.end), location: a.location)
            return ok ? nil : "Takvimdeki etkinliği değiştiremedim; takvim iznini kontrol eder misin?"

        case "delete_event":
            guard let id = a.target_id else { return nil }
            let ok = await CalendarService.shared.delete(id: id)
            return ok ? nil : "Takvimdeki etkinliği silemedim."

        case "open_maps":
            guard let dest = a.destination, !dest.isEmpty else { return nil }
            let ok = await RouteService.shared.openDirections(to: dest, from: a.origin)
            return ok ? nil : "Bu adresi haritada bulamadım."

        case "send_message":
            guard let person = a.person, !person.isEmpty, let text = a.note, !text.isEmpty else { return nil }
            let ok = await ContactsService.message(person, text: text, whatsapp: (a.title ?? "").lowercased().contains("whatsapp"))
            return ok ? nil : "\(person) rehberde telefon numarasıyla bulunamadı."

        case "call_now":
            guard let person = a.person ?? a.title, !person.isEmpty else { return nil }
            let ok = await ContactsService.call(person)
            return ok ? nil : "\(person) rehberde bulunamadı ya da rehber izni kapalı."

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
            if let id = a.target_id { store.trashMemory(id: id) }
            return nil

        case "add_special_day":
            guard let title = a.title, !title.isEmpty, let date = DateText.parseDay(a.due) else { return nil }
            let cal = Calendar.current
            let c = cal.dateComponents([.year, .month, .day], from: date)
            let thisYear = cal.component(.year, from: Date())
            var day = SpecialDay(title: title, person: a.person, month: c.month ?? 1, day: c.day ?? 1,
                                 kind: SpecialKind.from(a.note ?? title), note: nil)
            if let y = c.year, y < thisYear { day.year = y }   // geçmiş yıl verildiyse: doğum / başlangıç yılı
            store.addSpecial(day)
            return nil

        case "delete_special_day":
            if let id = a.target_id { store.removeSpecial(id: id) }
            return nil

        case "add_moment":
            guard let title = a.title, !title.isEmpty else { return nil }
            store.addMoment(Moment(title: title, date: DateText.parseDay(a.due) ?? Date(), place: a.location, note: a.note))
            return nil

        case "show_calendar":
            calendarRequest = CalendarPage(rawValue: a.note ?? "week") ?? .week
            return nil

        default:
            return nil
        }
    }

    private static func items(_ a: AssistantAction) -> [String] {
        let list = a.items ?? []
        return list.isEmpty ? [a.title].compactMap { $0 } : list
    }

    private static func isDaily(_ note: String?) -> Bool {
        let n = (note ?? "").lowercased(with: Locale(identifier: "tr_TR"))
        return n.contains("daily") || n.contains("günlük") || n.contains("her gün")
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
