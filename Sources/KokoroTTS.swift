import Foundation

/// Natural-sounding local speech with Kokoro, run by kokoro_server.py in its own Python venv.
/// The worker starts on demand and exits by itself after 10 idle minutes.
final class KokoroTTS {
    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Buddy/kokoro")
    static let python = dir.appendingPathComponent("venv/bin/python")
    static let script = Bundle.main.url(forResource: "kokoro_server", withExtension: "py")

    static var available: Bool {
        let fm = FileManager.default
        return script != nil && fm.isExecutableFile(atPath: python.path)
            && fm.fileExists(atPath: dir.appendingPathComponent("kokoro-v1.0.onnx").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("voices-v1.0.bin").path)
    }

    static let voices = [
        ("Heart (US, warm)", "af_heart"), ("Bella (US)", "af_bella"), ("Michael (US)", "am_michael"),
        ("Emma (UK)", "bf_emma"), ("George (UK)", "bm_george"),
    ]

    private var process: Process?
    private var input: FileHandle?
    private var nextID = 0
    private var pending: [Int: (URL?) -> Void] = [:]

    /// Starts the worker early so the model is loaded by the time there's something to say.
    func prepare() { _ = ensureProcess() }

    /// Calls back on the main queue with a WAV file, or nil if Kokoro couldn't do it.
    func synthesize(_ text: String, voice: String, speed: Double = 1.05, completion: @escaping (URL?) -> Void) {
        guard let input = ensureProcess() else { completion(nil); return }
        nextID += 1
        let id = nextID
        pending[id] = completion
        let request: [String: Any] = ["id": id, "text": text, "voice": voice, "speed": speed]
        guard var data = try? JSONSerialization.data(withJSONObject: request) else { pending[id] = nil; completion(nil); return }
        data.append(0x0A)
        do { try input.write(contentsOf: data) } catch { pending.removeValue(forKey: id)?(nil) }
    }

    private func ensureProcess() -> FileHandle? {
        if let input, process?.isRunning == true { return input }
        guard Self.available, let script = Self.script else { return nil }

        let p = Process()
        p.executableURL = Self.python
        p.arguments = ["-I", script.path, Self.dir.path]
        p.currentDirectoryURL = Self.dir
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice

        var lineBuffer = Data()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            lineBuffer.append(chunk)
            while let newline = lineBuffer.firstIndex(of: 0x0A) {
                let line = lineBuffer[lineBuffer.startIndex..<newline]
                lineBuffer = Data(lineBuffer[lineBuffer.index(after: newline)...])
                guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let id = obj["id"] as? Int else { continue }
                let url = (obj["path"] as? String).map { URL(fileURLWithPath: $0) }
                DispatchQueue.main.async { self?.pending.removeValue(forKey: id)?(url) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.process === proc else { return }
                self.process = nil
                self.input = nil
                let failed = self.pending
                self.pending.removeAll()
                failed.values.forEach { $0(nil) }
            }
        }

        do { try p.run() } catch { return nil }
        process = p
        input = inPipe.fileHandleForWriting
        return input
    }
}
