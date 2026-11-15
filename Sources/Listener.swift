import AVFoundation
import CoreAudio
import Speech

/// Always-on, Siri-style listening for "Hey Buddy".
/// Apple's recognizer, locked to on-device mode so no audio leaves the Mac, spots the wake phrase.
/// The speech that follows is captured until you stop talking, then handed over as 16 kHz audio
/// (for Whisper) together with Apple's own transcript as a fallback.
final class Listener {
    var onWake: (() -> Void)?
    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onCommand: (([Float], String) -> Void)?
    /// Woke up, but nothing was said.
    var onSilence: (() -> Void)?

    private(set) var running = false
    private(set) var capturing = false
    /// Capturing, but still letting the room go quiet before audio counts (see `listenNow(afterSpeech:)`).
    private var settling = false
    /// Locked listening: pauses don't end the capture; `finishNow()` (Return) does.
    var held = false
    var available: Bool { recognizer != nil }

    /// Only a recognizer that can run fully on-device is ever used for always-on listening.
    private let recognizer: SFSpeechRecognizer? = {
        for locale in [Locale.current, Locale(identifier: "en-US")] {
            if let r = SFSpeechRecognizer(locale: locale), r.supportsOnDeviceRecognition { return r }
        }
        return nil
    }()

    private static let sampleRate = Whisper.sampleRate
    // Rebuilt whenever the input device changes: on macOS an engine keeps pointing at the old device.
    private var engine = AVAudioEngine()
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var restartWork: DispatchWorkItem?
    private var lastBuffer: CFTimeInterval = 0
    private var watchdog: Timer?
    private let format16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Whisper.sampleRate, channels: 1, interleaved: false)!
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var refreshTimer: Timer?
    private var configObserver: NSObjectProtocol?

    // Shared with the audio thread: the current request and the 16 kHz audio since it started.
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var samples: [Float] = []

    // Command capture (main thread).
    private var commandStart = 0
    private var commandFirstSegment = 0
    private var commandText = ""
    private var captureBegan: CFTimeInterval = 0
    private var speechTime: Double = 0
    private var lastSpeech: CFTimeInterval = 0
    private var noiseFloor: Float = 0.25
    private var lastSegmentCount = 0

    private static let heyWords: Set<String> = ["hey", "hi", "hay", "okay", "ok", "play", "they", "yay", "pay", "a"]
    private static let buddyWords: Set<String> = ["buddy", "buddie", "budi", "body", "birdie"]

    /// "Hey Buddy" and the ways the recognizer commonly mishears it, but not everyday phrases like "a body".
    private static func isWake(_ first: String, _ second: String) -> Bool {
        guard heyWords.contains(first), buddyWords.contains(second) else { return first + second == "heybuddy" }
        if first == "a" { return second == "buddy" || second == "buddie" }
        return true
    }

    static func requestPermissions(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speech in
            AVCaptureDevice.requestAccess(for: .audio) { mic in
                DispatchQueue.main.async { done(mic && speech == .authorized) }
            }
        }
    }

    /// Removes a leading "Hey Buddy," that the command audio may still contain.
    static func stripWakePhrase(_ text: String) -> String {
        text.replacingOccurrences(of: #"^[\s,.!?]*(?:(?:hey|hi|hay|okay|ok|a)[\s,]+)?(?:buddy|buddie|body)\b[\s,.!?]*"#,
                                  with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Lifecycle

    func start() throws {
        guard !running else { return }
        guard recognizer != nil else {
            throw NSError(domain: "Buddy", code: 1, userInfo: [NSLocalizedDescriptionKey: "On-device speech recognition isn't available."])
        }
        try startEngine()
        running = true
        startRecognition()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak self] _ in
            // Recognition tasks don't run forever; start a fresh one regularly while idle.
            if self?.capturing == false { self?.startRecognition() }
        }
        // Headphones plugged in, AirPods connected, etc.: the engine reports a configuration change,
        // and CoreAudio reports a new default microphone. Either one rebuilds the audio path.
        observeEngine()
        var address = Self.defaultInputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.restartAudio() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        deviceListener = listener
        // Catch-all: if no audio has arrived for a while, the route changed without telling us.
        lastBuffer = CACurrentMediaTime()
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.running, CACurrentMediaTime() - self.lastBuffer > 4 else { return }
            self.restartAudio()
        }
    }

    private static var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func observeEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restartAudio()
        }
    }

    /// Throws away the audio engine and builds a new one on the current microphone, then starts
    /// listening for the wake phrase again. Coalesces the burst of notifications a route change sends,
    /// and retries while the new device is still coming up.
    private func restartAudio(attempt: Int = 0) {
        guard running else { return }
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            if self.engine.isRunning { self.engine.stop() }
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine = AVAudioEngine()
            self.observeEngine()
            do {
                try self.startEngine()
                self.lastBuffer = CACurrentMediaTime()
                // The old request was fed audio in the old format: start a clean one. A command you
                // were in the middle of saying is delivered as far as it got.
                if self.capturing {
                    self.finishCapture(spoke: self.speechTime > 0.25 || !self.commandText.isEmpty)
                } else {
                    self.startRecognition()
                }
            } catch {
                guard attempt < 8 else { return } // the watchdog keeps trying after this
                self.restartAudio(attempt: attempt + 1)
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.4 : 1), execute: work)
    }

    func stop() {
        running = false
        capturing = false
        settling = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let deviceListener {
            var address = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, deviceListener)
        }
        deviceListener = nil
        restartWork?.cancel()
        watchdog?.invalidate()
        watchdog = nil
        generation += 1
        task?.cancel()
        task = nil
        lock.withLock { request = nil; samples.removeAll() }
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Start capturing a command right now, without the wake phrase (follow-up answers, menu).
    /// Right after Buddy has spoken, its last word is still echoing and still on its way through the
    /// recognizer, so it would open the capture: drop everything heard so far and start fresh a moment later.
    func listenNow(afterSpeech: Bool = false) {
        guard running, !capturing else { return }
        guard afterSpeech else {
            beginCapture(at: lock.withLock { samples.count }, firstSegment: lastSegmentCount)
            return
        }
        capturing = true
        settling = true
        generation += 1
        let gen = generation
        task?.cancel()
        task = nil
        lock.withLock { request?.endAudio(); request = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, gen == self.generation, self.capturing else { return }
            self.startRecognition() // fresh request and samples: nothing from before this point
            self.beginCapture(at: 0, firstSegment: 0)
        }
    }

    /// Drop the current capture without delivering it.
    func cancelCapture() {
        held = false
        guard capturing else { return }
        capturing = false
        settling = false
        startRecognition()
    }

    /// End a locked capture now and deliver what was said.
    func finishNow() {
        guard capturing else { held = false; return }
        finishCapture(spoke: speechTime > 0.25 || !commandText.isEmpty)
    }

    // MARK: Audio

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let converter = AVAudioConverter(from: format, to: format16k) else {
            throw NSError(domain: "Buddy", code: 2, userInfo: [NSLocalizedDescriptionKey: "No microphone access."])
        }
        let target = format16k
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            DispatchQueue.main.async { self.lastBuffer = CACurrentMediaTime() }
            let req = self.lock.withLock { self.request }
            req?.append(buffer)

            // Loudness, for the orb and for noticing when you've stopped talking.
            if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                var sum: Float = 0
                for i in 0..<Int(buffer.frameLength) { sum += channel[i] * channel[i] }
                let db = 20 * log10(max(sqrt(sum / Float(buffer.frameLength)), 1e-6))
                let level = max(0, min(1, (db + 50) / 40))
                let seconds = Double(buffer.frameLength) / format.sampleRate
                DispatchQueue.main.async { self.heard(level: level, seconds: seconds) }
            }

            // Keep a 16 kHz copy for Whisper.
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / format.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard let data = out.floatChannelData?[0] else { return }
            let chunk = UnsafeBufferPointer(start: data, count: Int(out.frameLength))
            self.lock.withLock {
                self.samples.append(contentsOf: chunk)
                let cap = Int(Self.sampleRate * 200)
                if self.samples.count > cap { self.samples.removeFirst(self.samples.count - cap) }
            }
        }
        engine.prepare()
        try engine.start()
    }

    // MARK: Recognition

    private func startRecognition() {
        guard running, let recognizer else { return }
        generation += 1
        let gen = generation
        task?.cancel()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true // never stream always-on audio to a server
        req.contextualStrings = ["Hey Buddy", "Buddy"]
        lock.withLock {
            request?.endAudio()
            request = req
            samples.removeAll(keepingCapacity: true)
        }
        lastSegmentCount = 0

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                if let result { self.handle(result) }
                if error != nil || result?.isFinal == true, !self.capturing {
                    // Ended by itself (silence, time limit): start listening again shortly.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if gen == self.generation { self.startRecognition() }
                    }
                }
            }
        }
    }

    private func handle(_ result: SFSpeechRecognitionResult) {
        let segments = result.bestTranscription.segments
        lastSegmentCount = segments.count

        if capturing {
            let words = segments.dropFirst(commandFirstSegment).map(\.substring)
            commandText = Self.stripWakePhrase(words.joined(separator: " "))
            onPartial?(commandText)
            return
        }

        // Words with the segment each came from: a contextual phrase like "Hey Buddy" can arrive as one segment.
        let words: [(text: String, segment: Int)] = segments.enumerated().flatMap { i, s in
            s.substring.lowercased().split(separator: " ").map { (String($0).trimmingCharacters(in: .punctuationCharacters), i) }
        }
        guard words.count >= 2 else { return }
        for j in 1..<words.count where Self.isWake(words[j - 1].text, words[j].text) {
            let i = words[j].segment
            let wake = segments[i]
            let now = lock.withLock { samples.count }
            // Segment timings can be missing in partial results; then assume the wake word just ended.
            let start = wake.timestamp > 0
                ? Int((wake.timestamp + wake.duration) * Self.sampleRate)
                : now - Int(Self.sampleRate * 0.8)
            beginCapture(at: max(0, min(start, now)), firstSegment: i + 1)
            onWake?()
            return
        }
    }

    // MARK: Capture

    private func beginCapture(at sample: Int, firstSegment: Int) {
        capturing = true
        settling = false
        commandStart = sample
        commandFirstSegment = firstSegment
        commandText = ""
        captureBegan = CACurrentMediaTime()
        speechTime = 0
        lastSpeech = captureBegan
    }

    private func heard(level: Float, seconds: Double) {
        guard running else { return }
        onLevel?(level)
        if settling { return } // Buddy's own voice dying away: neither speech nor background noise
        guard capturing else {
            // Track the room's background noise so "speaking" is relative to it.
            noiseFloor = level < noiseFloor ? level : noiseFloor + (level - noiseFloor) * 0.002
            return
        }
        let now = CACurrentMediaTime()
        let elapsed = now - captureBegan
        // Ignore the first moment, which may still be the tail of "Buddy".
        if elapsed > 0.35 && level > max(noiseFloor + 0.18, 0.3) {
            speechTime += seconds
            lastSpeech = now
        }
        let spoke = speechTime > 0.25
        if held {
            if elapsed > 180 { finishCapture(spoke: spoke || !commandText.isEmpty) } // safety limit, ~3 minutes
            return
        }
        if (spoke && now - lastSpeech > 1.5) || (!spoke && elapsed > 6) || elapsed > 25 {
            finishCapture(spoke: spoke)
        }
    }

    private func finishCapture(spoke: Bool) {
        let spoke = spoke && !settling
        capturing = false
        settling = false
        held = false
        let audio: [Float] = lock.withLock {
            let start = min(commandStart, samples.count)
            return Array(samples[start...])
        }
        let text = commandText
        startRecognition() // fresh task so the same "Hey Buddy" can't trigger twice
        if spoke { onCommand?(audio, text) } else { onSilence?() }
    }
}
