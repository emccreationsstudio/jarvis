import Foundation
import Speech
import AVFoundation

/// Mikrofondan gelen sesi tanıma isteğine aktaran, iş parçacığı güvenli küçük kutu.
/// (Ses motoru kendi iş parçacığında çalışır; tanıma isteği oturum boyunca yenilenir.)
final class BufferSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ r: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); request = r; lock.unlock()
    }
    private var last: TimeInterval = 0
    private var lastSignal: TimeInterval = 0
    func append(_ b: AVAudioPCMBuffer) {
        let now = Date().timeIntervalSince1970
        var peak: Float = 0
        if let d = b.floatChannelData?[0] {
            let n = Int(b.frameLength)
            var i = 0
            while i < n { peak = max(peak, abs(d[i])); i += 4 }
        }
        lock.lock()
        request?.append(b)
        last = now
        // Gerçek bir mikrofonda sessiz odada bile hafif gürültü olur. Tamamen sıfır ses = mikrofon başka
        // bir yerde (ör. Siri hâlâ tutuyor), bize boş ses geliyor.
        if peak > 0.00001 { lastSignal = now }
        lock.unlock()
    }
    /// Mikrofondan en son ses parçasının geldiği an (hiç gelmediyse 0)
    var lastBuffer: TimeInterval { lock.lock(); defer { lock.unlock() }; return last }
    /// En son sıfırdan farklı (gerçek) sesin geldiği an
    var lastRealSound: TimeInterval { lock.lock(); defer { lock.unlock() }; return lastSignal }
    func resetClock() { lock.lock(); last = 0; lastSignal = Date().timeIntervalSince1970; lock.unlock() }
}

/// Türkçe konuşmayı sürekli dinler (cihaz üzerinde) ve her duraksamada söyleneni parça olarak bildirir.
/// Cevapları sesli okur.
@MainActor
final class SpeechService: NSObject, ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var partialText = ""
    @Published private(set) var level: Float = 0

    /// Bu kadar sessizlik olunca söylenen bir "parça" sayılır
    var pauseInterval: TimeInterval = 1.3
    /// Tanımayı kolaylaştıran özel sözcükler: Jarvis, kişi adları, liste ve ürün adları…
    var vocabulary: [String] = []

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR"))
    // 1.2.1: her dinlemede TAZE ses motoru. Konuştuktan sonra eski motor eski ses biçimiyle kalıyor,
    // mikrofon "açık" görünse de hiç ses gelmiyordu → "Dinliyorum"da takılıp kalıyordu.
    private var engine = AVAudioEngine()
    private var micWatch: Task<Void, Never>?
    private var micRestarts = 0
    /// Mikrofon defalarca denenip hiç ses alınamadıysa true (ekranda uyarı gösterilir)
    @Published private(set) var micDead = false
    private var observers: [NSObjectProtocol] = []
    private let sink = BufferSink()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recogTask: SFSpeechRecognitionTask?
    private var pauseTimer: Timer?
    private var generation = 0
    private var onSegment: ((String) -> Void)?

    private let synth = AVSpeechSynthesizer()
    private var speakDone: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
        // Kulaklık takıldı/çıkarıldı, arama geldi, ses sistemi sıfırlandı → dinliyorsak mikrofonu yeniden kur
        let nc = NotificationCenter.default
        for name in [AVAudioSession.routeChangeNotification, AVAudioSession.interruptionNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.restartMicSoon() }
            })
        }
    }

    private var restartPending = false
    private func restartMicSoon() {
        guard isListening, !restartPending, let cb = onSegment else { return }
        restartPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self else { return }
            self.restartPending = false
            guard self.isListening else { return }
            self.stopMic()
            _ = self.startMic(onSegment: cb)
        }
    }

    /// Ses oturumunu tek kategoride tut (konuşma ve dinleme ikisi de). Kategori değiştirmek iOS'ta ses
    /// yolunu değiştirip mikrofonun sessiz kalmasına yol açıyordu.
    private func prepareSession() throws {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord || session.mode != .default {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.duckOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        }
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    // MARK: İzinler

    func requestPermissions() async -> Bool {
        let speechOK: Bool = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in cont.resume(returning: status == .authorized) }
        }
        let micOK = await AVAudioApplication.requestRecordPermission()
        return speechOK && micOK
    }

    // MARK: Sürekli dinleme

    /// Mikrofonu açar. Her duraksamada `onSegment` söylenen cümleyle çağrılır.
    @discardableResult
    func startMic(onSegment: @escaping (String) -> Void) -> Bool {
        self.onSegment = onSegment
        guard !isListening else { return true }
        guard let recognizer, recognizer.isAvailable else { return false }

        do {
            try prepareSession()
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
            engine = AVAudioEngine()                       // taze motor: güncel mikrofon biçimiyle
            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            // Ses sistemi henüz hazır değilse biçim 0 Hz gelir; bununla dinlemeye başlamak çöktürüyordu
            guard format.sampleRate > 0, format.channelCount > 0 else { return false }
            let sink = self.sink
            sink.resetClock()
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
                sink.append(buffer)
                let lvl = SpeechService.rms(buffer)
                Task { @MainActor in
                    self?.level = lvl
                    if lvl > 0.2, let me = self {
                        let n = Date()
                        if n.timeIntervalSince(me.lastLoudAt) > 1.5 { me.loudStreakStart = n }   // yeni konuşma başladı
                        me.lastLoudAt = n
                    }
                }
            }
            engine.prepare()
            try engine.start()
            isListening = true
            lastPartialAt = Date()
            startRecognition()
            watchMic()
            return true
        } catch {
            stopMic()
            return false
        }
    }

    /// Mikrofon açık görünüp hiç ses gelmiyorsa (iOS bazen sessiz bırakıyor) kendiliğinden yeniden kur.
    private func watchMic() {
        micWatch?.cancel()
        micWatch = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled, self.isListening, let cb = self.onSegment else { return }
            let now = Date().timeIntervalSince1970
            let last = self.sink.lastBuffer
            let dead = last == 0 || now - last > 2.0 || now - self.sink.lastRealSound > 2.5
            if dead {
                guard self.micRestarts < 6 else { self.micDead = true; return }
                self.micRestarts += 1
                self.stopMic()
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                try? await Task.sleep(nanoseconds: 800_000_000)
                if !self.startMic(onSegment: cb) {        // ses sistemi hâlâ meşgul: biraz daha bekle, bir kez daha dene
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    _ = self.startMic(onSegment: cb)
                }
            } else {
                self.micRestarts = 0
                self.micDead = false
                // Konuşuluyor (ses yüksek) ama tanıma 6 sn'dir hiç yazı üretmiyorsa: tanıma yolunu değiştir
                let n = Date()
                if n.timeIntervalSince(self.lastLoudAt) < 2, n.timeIntervalSince(self.loudStreakStart) > 4,
                   self.lastPartialAt < self.loudStreakStart {
                    self.flipOnDevice.toggle()
                    self.lastPartialAt = n
                    self.startRecognition()
                }
                self.watchMic()                              // dinleme sürdükçe kontrol et
            }
        }
    }

    /// Mikrofonu kapatır (ör. Jarvis konuşurken kendini duymasın diye). Yarım kalan söz atılır.
    func stopMic() {
        micWatch?.cancel(); micWatch = nil
        pauseTimer?.invalidate(); pauseTimer = nil
        generation += 1
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        sink.set(nil)
        request?.endAudio()
        recogTask?.cancel()
        request = nil
        recogTask = nil
        isListening = false
        partialText = ""
        level = 0
    }

    /// Şu ana kadar söyleneni hemen parça olarak bildir (duraksamayı beklemeden).
    func flush() {
        guard isListening else { return }
        emitSegment()
    }

    private func startRecognition() {
        guard let recognizer else { return }
        generation += 1
        let gen = generation
        recogTask?.cancel()
        request?.endAudio()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        if !vocabulary.isEmpty { req.contextualStrings = Array(vocabulary.prefix(100)) }
        // Apple'ın sunucudaki tanıması Türkçede cihazdakinden belirgin şekilde daha doğru.
        // "Gelişmiş tanıma" kapalıysa (ya da internet yoksa) cihaz üzerinde tanınır.
        if recognizer.supportsOnDeviceRecognition {
            var onDevice = !AppSettings.shared.cloudRecognition || serverRecognitionFailures >= 2
            if flipOnDevice { onDevice.toggle() }          // bu yol üst üste hata veriyor: diğerini dene
            req.requiresOnDeviceRecognition = onDevice
        }
        request = req
        sink.set(req)
        partialText = ""

        recognitionMode = req.requiresOnDeviceRecognition ? "cihaz" : "bulut"
        recogTask = recognizer.recognitionTask(with: req) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let code = (error as NSError?)?.code ?? 0
            // 1110 = konuşma duyulmadı, 216/301 = biz iptal ettik: bunlar arıza değil
            let failed = error != nil
            let realError = error != nil && ![1110, 216, 301].contains(code)
            let errInfo: String? = error.map { e in
                let ns = e as NSError
                return "\(ns.domain.replacingOccurrences(of: "kAFAssistantErrorDomain", with: "Siri")) \(ns.code): \(ns.localizedDescription)"
            }
            Task { @MainActor in
                if realError, let errInfo { self?.lastRecogError = errInfo }
                self?.handle(gen: gen, text: text, isFinal: isFinal, failed: failed, realError: realError)
            }
        }
    }

    /// Sunucu tanıması üst üste başarısız olursa (internet yok) cihaz üzerine geç
    private var serverRecognitionFailures = 0

    // 1.2.3: tanıma hata verip boş dönünce eskiden sessizce yeniden başlıyordu → sonsuz döngü, ekran "Dinliyorum"da
    // kalıyordu. Artık hatalar sayılıyor: 3 kez üst üste olursa tanıma yolu değiştiriliyor (bulut ↔ cihaz),
    // 6 kez olursa ekranda nedeni gösteriliyor.
    @Published private(set) var recognitionMode = ""
    @Published private(set) var lastRecogError: String?
    @Published private(set) var recognitionBroken: String?
    private var emptyFails = 0
    private var flipOnDevice = false
    private var lastLoudAt = Date.distantPast
    private var loudStreakStart = Date.distantPast
    private var lastPartialAt = Date()

    private func handle(gen: Int, text: String?, isFinal: Bool, failed: Bool, realError: Bool = false) {
        guard gen == generation, isListening else { return }
        if realError && (text ?? "").isEmpty {
            serverRecognitionFailures += 1
            emptyFails += 1
            if emptyFails % 3 == 0 { flipOnDevice.toggle() }
            if emptyFails >= 6 {
                recognitionBroken = "Konuşma tanıma çalışmıyor (\(lastRecogError ?? "bilinmeyen hata")). iPhone Ayarlar → Siri'de \"Siri ve Dikte\" açık mı, Türkçe dikte yüklü mü bakın."
            }
        }
        if let text, !text.isEmpty { serverRecognitionFailures = 0; emptyFails = 0; recognitionBroken = nil }
        if let text, text != partialText {
            partialText = text
            lastPartialAt = Date()
            if !text.isEmpty { schedulePause() }
        }
        if isFinal || failed {
            if partialText.trimmingCharacters(in: .whitespaces).isEmpty {
                // Konuşma yokken tanıma kapandı (ör. süre doldu) → kısa bekleyip yeniden başla
                let g = generation
                let wait: UInt64 = emptyFails >= 6 ? 3_000_000_000 : 400_000_000   // bozuksa sistemi yormadan yavaş dene
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: wait)
                    guard let self, self.isListening, self.generation == g else { return }
                    self.startRecognition()
                }
            } else {
                emitSegment()
            }
        }
    }

    private func schedulePause() {
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: pauseInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.emitSegment() }
        }
    }

    private func emitSegment() {
        pauseTimer?.invalidate(); pauseTimer = nil
        let text = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        startRecognition()   // yeni cümle için temiz sayfa
        if !text.isEmpty { onSegment?(text) }
    }

    nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        return min(1, sqrt(sum / Float(n)) * 12)
    }

    // MARK: Konuşma
    //
    // Doğal ses: sunucu üzerinden OpenAI sesi (akıcı, insan gibi). İlk cümle hemen istenir,
    // gerisi paralel hazırlanır → bekleme kısa olur. İnternet/sunucu yoksa iPhone sesine düşer.

    private var player: AVAudioPlayer?
    private var queue: [Task<Data?, Never>] = []
    private var queueTexts: [String] = []
    private var playTask: Task<Void, Never>?

    func speak(_ text: String, completion: (() -> Void)? = nil) {
        speakDone = nil          // önceki konuşmanın devamı tetiklenmesin
        haltAudio()
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { completion?(); return }
        try? prepareSession()          // dinlemeyle aynı kategori: geri dönüşte mikrofon sessiz kalmasın
        speakDone = completion
        isSpeaking = true

        let s = AppSettings.shared
        guard s.naturalVoice, s.isConfigured else { speakSystem(clean); return }

        let chunks = Self.chunks(clean)
        let voice = s.voiceName, speed = s.voiceSpeed, base = s.serverURL, token = s.token
        queueTexts = chunks
        queue = chunks.map { chunk in
            Task.detached { await SpeechService.fetchTTS(chunk, voice: voice, speed: speed, base: base, token: token) }
        }
        playTask = Task { [weak self] in await self?.playQueue() }
    }

    private func playQueue() async {
        var index = 0
        while index < queue.count {
            let data = await queue[index].value
            guard isSpeaking, !Task.isCancelled else { return }
            guard let data, let p = try? AVAudioPlayer(data: data) else {
                // Doğal ses alınamadı → kalanını iPhone sesiyle oku
                speakSystem(queueTexts[index...].joined(separator: " "))
                return
            }
            player = p
            p.prepareToPlay()
            p.play()
            while p.isPlaying && isSpeaking && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard isSpeaking, !Task.isCancelled else { return }
            index += 1
        }
        finishSpeaking()
    }

    private func speakSystem(_ text: String) {
        let utt = AVSpeechUtterance(string: text)
        utt.voice = Self.bestTurkishVoice()
        let s = AppSettings.shared
        utt.rate = Float(min(0.62, max(0.4, 0.5 * s.voiceSpeed)))
        utt.pitchMultiplier = Float(0.8 + s.voiceTone * 0.4)
        utt.postUtteranceDelay = 0.05
        synth.speak(utt)
    }

    fileprivate func finishSpeaking() {
        guard isSpeaking else { return }
        isSpeaking = false
        player = nil
        queue = []
        queueTexts = []
        let cb = speakDone
        speakDone = nil
        cb?()
    }

    private func haltAudio() {
        playTask?.cancel(); playTask = nil
        queue.forEach { $0.cancel() }
        queue = []
        queueTexts = []
        player?.stop(); player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    /// Konuşmayı keser. Bekleyen tamamlama yine çağrılır (akış devam etsin diye).
    func stopSpeaking() {
        guard isSpeaking || synth.isSpeaking || player != nil else { return }
        haltAudio()
        isSpeaking = false
        let cb = speakDone
        speakDone = nil
        cb?()
    }

    /// İlk cümle ayrı (hızlı başlasın), gerisi en fazla ~300 karakterlik parçalar.
    nonisolated static func chunks(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { sub, _, _, _ in
            if let t = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { sentences.append(t) }
        }
        if sentences.isEmpty { return [text] }
        var out = [sentences.removeFirst()]
        var current = ""
        for s in sentences {
            if current.count + s.count > 300, !current.isEmpty { out.append(current); current = "" }
            current += (current.isEmpty ? "" : " ") + s
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    nonisolated static func fetchTTS(_ text: String, voice: String, speed: Double, base: String, token: String) async -> Data? {
        let root = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: root + "/tts") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let payload: [String: Any] = ["text": text, "voice": voice, "speed": speed]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        guard let result = try? await URLSession.shared.data(for: req) else { return nil }
        guard (result.1 as? HTTPURLResponse)?.statusCode == 200, !result.0.isEmpty else { return nil }
        return result.0
    }

    private static func bestTurkishVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("tr") }
        return voices.first { $0.quality == .premium }
            ?? voices.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "tr-TR")
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard !self.synth.isSpeaking else { return }
            self.finishSpeaking()
        }
    }
}
