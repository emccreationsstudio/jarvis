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
    func append(_ b: AVAudioPCMBuffer) {
        lock.lock(); request?.append(b); lock.unlock()
    }
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
    private let engine = AVAudioEngine()
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
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            let sink = self.sink
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
                sink.append(buffer)
                let lvl = SpeechService.rms(buffer)
                Task { @MainActor in self?.level = lvl }
            }
            engine.prepare()
            try engine.start()
            isListening = true
            startRecognition()
            return true
        } catch {
            stopMic()
            return false
        }
    }

    /// Mikrofonu kapatır (ör. Jarvis konuşurken kendini duymasın diye). Yarım kalan söz atılır.
    func stopMic() {
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
            req.requiresOnDeviceRecognition = !AppSettings.shared.cloudRecognition || serverRecognitionFailures >= 2
        }
        request = req
        sink.set(req)
        partialText = ""

        recogTask = recognizer.recognitionTask(with: req) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                self?.handle(gen: gen, text: text, isFinal: isFinal, failed: failed)
            }
        }
    }

    /// Sunucu tanıması üst üste başarısız olursa (internet yok) cihaz üzerine geç
    private var serverRecognitionFailures = 0

    private func handle(gen: Int, text: String?, isFinal: Bool, failed: Bool) {
        guard gen == generation, isListening else { return }
        if failed && (text ?? "").isEmpty { serverRecognitionFailures += 1 }
        if let text, !text.isEmpty { serverRecognitionFailures = 0 }
        if let text, text != partialText {
            partialText = text
            if !text.isEmpty { schedulePause() }
        }
        if isFinal || failed {
            if partialText.trimmingCharacters(in: .whitespaces).isEmpty {
                // Konuşma yokken tanıma kapandı (ör. süre doldu) → kısa bekleyip yeniden başla
                let g = generation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 400_000_000)
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
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {}
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
