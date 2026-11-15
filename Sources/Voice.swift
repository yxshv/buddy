import AVFoundation

/// Speaks replies sentence by sentence and runs a callback as each sentence starts,
/// so the cursor flies to its target in sync with the speech.
/// Uses Kokoro when it's installed (the next sentence is synthesized while the current one plays)
/// and Apple's voice otherwise, or for any sentence Kokoro fails on.
final class Voice: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    var enabled = true
    var onIdle: (() -> Void)?
    /// A Kokoro voice id (see `KokoroTTS.voices`) or "apple" for the system voice.
    var voiceID = "af_heart"
    var isSpeaking: Bool { playing || !queue.isEmpty }
    var usingKokoro: Bool { voiceID != "apple" && KokoroTTS.available }

    private final class Item {
        let text: String
        let onStart: () -> Void
        var ready = false
        var audio: URL?
        init(text: String, onStart: @escaping () -> Void) { self.text = text; self.onStart = onStart }
    }

    private let synth = AVSpeechSynthesizer()
    private let kokoro = KokoroTTS()
    private var queue: [Item] = []
    private var player: AVAudioPlayer?
    private var playingFile: URL?
    private var playing = false
    private var generation = 0
    private lazy var appleVoice = Voice.bestVoice()

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Loads Kokoro in the background so the first sentence of the reply isn't delayed.
    func prepare() {
        if enabled && usingKokoro { kokoro.prepare() }
    }

    func say(_ text: String, onStart start: @escaping () -> Void) {
        guard enabled, !text.isEmpty else { start(); return }
        let item = Item(text: text, onStart: start)
        queue.append(item)
        guard usingKokoro else {
            item.ready = true
            pump()
            return
        }
        let gen = generation
        kokoro.synthesize(text, voice: voiceID) { [weak self] url in
            guard let self, gen == self.generation else {
                if let url { try? FileManager.default.removeItem(at: url) }
                return
            }
            item.audio = url
            item.ready = true
            self.pump()
        }
    }

    func stop() {
        generation += 1
        queue.forEach { if let url = $0.audio { try? FileManager.default.removeItem(at: url) } }
        queue.removeAll()
        player?.stop()
        player = nil
        cleanUpFile()
        playing = false
        synth.stopSpeaking(at: .immediate)
    }

    /// Plays the next sentence once it's ready, keeping the original order.
    private func pump() {
        guard !playing, let item = queue.first, item.ready else { return }
        queue.removeFirst()
        playing = true
        if let url = item.audio, let p = try? AVAudioPlayer(contentsOf: url) {
            player = p
            playingFile = url
            p.delegate = self
            p.play()
        } else {
            if let url = item.audio { try? FileManager.default.removeItem(at: url) }
            let utterance = AVSpeechUtterance(string: item.text)
            utterance.voice = appleVoice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.08
            synth.speak(utterance)
        }
        item.onStart()
    }

    private func finished() {
        guard playing else { return }
        playing = false
        player = nil
        cleanUpFile()
        if queue.isEmpty { onIdle?() } else { pump() }
    }

    private func cleanUpFile() {
        if let url = playingFile { try? FileManager.default.removeItem(at: url) }
        playingFile = nil
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { if p === self.player { self.finished() } }
    }

    func audioPlayerDecodeErrorDidOccur(_ p: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { if p === self.player { self.finished() } }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { if self.player == nil { self.finished() } }
    }

    /// Picks the highest-quality installed English voice (Premium > Enhanced > default).
    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let current = AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice)
        }
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            var s = 0
            if v.quality == .premium { s += 20 } else if v.quality == .enhanced { s += 10 }
            if v.language == current { s += 2 }
            if v.language == "en-US" { s += 1 }
            return s
        }
        return voices.max { score($0) < score($1) } ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}
