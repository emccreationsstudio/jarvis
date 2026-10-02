import Foundation
import Speech
import AVFoundation

/// Türkçe konuşmayı yazıya çevirir (cihaz üzerinde, ücretsiz) ve cevapları sesli okur.
@MainActor
final class SpeechService: NSObject, ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var partialText = ""
    @Published private(set) var level: Float = 0

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var maxTimer: Timer?
    private var onFinish: ((String) -> Void)?
    private var finished = false

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

    // MARK: Dinleme

    func startListening(onFinish: @escaping (String) -> Void) {
        stopSpeaking()
        guard !isListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            onFinish("")
            return
        }
        self.onFinish = onFinish
        finished = false
        partialText = ""

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            request = req

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
                req.append(buffer)
                let lvl = Self.rms(buffer)
                Task { @MainActor in self?.level = lvl }
            }
            engine.prepare()
            try engine.start()
            isListening = true

            task = recognizer.recognitionTask(with: req) { @Sendable [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.partialText = result.bestTranscription.formattedString
                        self.resetSilenceTimer()
                        if result.isFinal { self.finish() }
                    }
                    if error != nil { self.finish() }
                }
            }

            // Hiç konuşulmazsa 6 sn, toplamda en fazla 30 sn
            silenceTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.finish() }
            }
            maxTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.finish() }
            }
        } catch {
            cleanup()
            onFinish("")
        }
    }

    /// Kullanıcı düğmeye tekrar basınca: söylenenle bitir
    func stopListening() {
        finish()
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        let text = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanup()
        let cb = onFinish
        onFinish = nil
        cb?(text)
    }

    private func cleanup() {
        silenceTimer?.invalidate(); silenceTimer = nil
        maxTimer?.invalidate(); maxTimer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
        level = 0
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        return min(1, sqrt(sum / Float(n)) * 12)
    }

    // MARK: Konuşma

    func speak(_ text: String, completion: (() -> Void)? = nil) {
        stopSpeaking()
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

    func stopSpeaking() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        isSpeaking = false
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
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            let cb = self.speakDone
            self.speakDone = nil
            cb?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
