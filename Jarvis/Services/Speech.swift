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
    var pauseInterval: TimeInterval = 1.8

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
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
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

    private func handle(gen: Int, text: String?, isFinal: Bool, failed: Bool) {
        guard gen == generation, isListening else { return }
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

    func speak(_ text: String, completion: (() -> Void)? = nil) {
        speakDone = nil          // önceki konuşmanın devamı tetiklenmesin
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        guard !text.isEmpty else { completion?(); return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {}
        let utt = AVSpeechUtterance(string: text)
        utt.voice = Self.bestTurkishVoice()
        utt.rate = 0.52
        utt.pitchMultiplier = 0.95
        speakDone = completion
        isSpeaking = true
        synth.speak(utt)
    }

    /// Konuşmayı keser. Bekleyen tamamlama yine çağrılır (akış devam etsin diye).
    func stopSpeaking() {
        guard synth.isSpeaking || isSpeaking else { return }
        synth.stopSpeaking(at: .immediate)
        isSpeaking = false
        let cb = speakDone
        speakDone = nil
        cb?()
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
            self.isSpeaking = false
            let cb = self.speakDone
            self.speakDone = nil
            cb?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
