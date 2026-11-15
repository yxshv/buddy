import Foundation

/// Local speech-to-text with whisper.cpp (`brew install whisper-cpp`) and the small.en model.
/// Runs only for a moment after you release the talk key; nothing stays loaded in between.
enum Whisper {
    static let sampleRate = 16_000.0

    static let binary = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static let model = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Buddy/models/ggml-small.en-q5_1.bin")

    static var available: Bool { binary != nil && FileManager.default.fileExists(atPath: model.path) }

    /// Transcribes 16 kHz mono samples; calls back on the main queue with nil on failure or silence.
    static func transcribe(_ samples: [Float], completion: @escaping (String?) -> Void) {
        guard let binary, available, samples.count > Int(sampleRate / 10) else {
            completion(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            var text: String?
            do {
                try writeWAV(samples, to: wav)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: binary)
                p.arguments = ["-m", model.path, "-f", wav.path, "-l", "en", "-nt", "-np"]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                try p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    // Drop Whisper's non-speech markers like [BLANK_AUDIO] or (wind blowing).
                    let cleaned = String(decoding: data, as: UTF8.self)
                        .replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                    text = cleaned.isEmpty ? nil : cleaned
                }
            } catch {}
            DispatchQueue.main.async { completion(text) }
        }
    }

    /// The first run compiles GPU shaders (several seconds); do it at launch so the first question is fast.
    static func warmUp() {
        transcribe([Float](repeating: 0, count: Int(sampleRate))) { _ in }
    }

    private static func writeWAV(_ samples: [Float], to url: URL) throws {
        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        for s in samples { put(Int16(max(-1, min(1, s)) * Float(Int16.max))) }
        try data.write(to: url)
    }
}
