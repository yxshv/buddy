import AppKit
import ApplicationServices
import Foundation

// MARK: - Features
//
// A feature is something you taught Buddy to do in one go ("check it", "set up this folder"): a folder
// holding `feature.json` and a script. Each one becomes a `buddy <command>` subcommand, a line in
// Claude's prompt, and a row in the Settings window. Nothing in the app is compiled per feature, so
// adding, editing or removing one never needs a rebuild. The guide is features/README.md.
//
// Features are read from two places, the second overriding the first by folder name:
//   1. built in:  Buddy.app/Contents/Resources/features   (the repo's features/ folder)
//   2. yours:     ~/Library/Application Support/Buddy/features

struct Feature {
    /// The folder name.
    let id: String
    let dir: URL
    let builtIn: Bool
    let manifest: Manifest
    /// Why it can't run (a missing script, a name Buddy already uses…), shown in Settings.
    var problem: String?

    /// feature.json. Only `command`, `title`, `summary` and `run` are required.
    struct Manifest: Codable {
        /// The subcommand: `buddy <command>`.
        var command: String
        var title: String
        /// One line: what it does. Goes into `buddy help` and Claude's prompt.
        var summary: String
        /// The script to run, relative to the feature's folder.
        var run: String
        /// Arguments after the command name, e.g. "[PREFIX]".
        var usage: String?
        /// Things you might say to mean this, so Claude recognises it.
        var phrases: [String]?
        /// "allow" (default) runs straight away; "ask" needs Touch ID every time.
        var permission: Level?
        /// One short sentence for Claude on how to use the result.
        var guidance: String?
        /// Seconds before the script is stopped (default 120).
        var timeout: Double?
    }

    /// The levels a feature can be set to.
    static let levels: [Level] = [.off, .ask, .allow]

    var command: String { manifest.command }
    var permissionID: String { "feature.\(id)" }
    /// The level before you choose one. A built-in feature starts where its manifest says; one of yours
    /// starts no looser than "Always ask", whatever its feature.json claims (loosening takes Touch ID).
    var defaultLevel: Level {
        let asked = manifest.permission.flatMap { Self.levels.contains($0) ? $0 : nil } ?? (builtIn ? .allow : .ask)
        return builtIn ? asked : min(asked, .ask)
    }

    /// A hash of every file in the folder: what you approve, and what must not change after.
    var hash: String? { FeatureHash.of(dir) }

    /// The hash this feature must have to run: built in, the one compiled into this Buddy; yours, the
    /// one you approved with Touch ID.
    var expectedHash: String? { builtIn ? BuiltinFeatures.hashes[id] : Permissions.shared.pin(id) }

    /// Anything new or edited (a script, a file it reads, feature.json) waits for your approval.
    var trusted: Bool {
        guard let expected = expectedHash else { return false }
        return hash == expected
    }

    var level: Level {
        let level = Permissions.shared.level(permissionID, fallback: defaultLevel)
        return Self.levels.contains(level) ? level : defaultLevel
    }
    var usable: Bool { problem == nil && level != .off && trusted }
    var usage: String { manifest.usage.map { "\(command) \($0)" } ?? command }
    var script: URL { dir.appendingPathComponent(manifest.run) }
}

enum FeatureStore {
    static let userDir: URL = {
        let dir = Buddy.supportDir.appendingPathComponent("features", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static let builtInDir: URL? = Bundle.main.resourceURL?.appendingPathComponent("features", isDirectory: true)

    /// Every feature, yours overriding built-in ones of the same folder name, sorted by title.
    /// Read from disk each time, so a new or edited folder works on the next command.
    static func all() -> [Feature] {
        var byID: [String: Feature] = [:]
        for (dir, builtIn) in [(builtInDir, true), (Optional(userDir), false)] {
            guard let dir, let folders = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if let feature = load(folder, builtIn: builtIn) { byID[feature.id] = feature }
            }
        }
        // Two features can't share a command; the later one (by folder name) is flagged.
        var seen: [String: String] = [:]
        var features: [Feature] = []
        // Who keeps a contested command: built in first, then approved, then by folder name.
        let ranked = byID.values.sorted { a, b in
            if a.builtIn != b.builtIn { return a.builtIn }
            if a.trusted != b.trusted { return a.trusted }
            return a.id < b.id
        }
        for var feature in ranked {
            if let other = seen[feature.command], feature.problem == nil {
                feature.problem = "The command “\(feature.command)” is already used by the feature “\(other)”."
            } else {
                seen[feature.command] = feature.id
            }
            features.append(feature)
        }
        return features.sorted { $0.manifest.title.localizedCaseInsensitiveCompare($1.manifest.title) == .orderedAscending }
    }

    private static func load(_ folder: URL, builtIn: Bool) -> Feature? {
        let file = folder.appendingPathComponent("feature.json")
        guard let data = try? Data(contentsOf: file) else { return nil } // not a feature folder
        let id = folder.lastPathComponent
        do {
            let manifest = try JSONDecoder().decode(Feature.Manifest.self, from: data)
            var feature = Feature(id: id, dir: folder, builtIn: builtIn, manifest: manifest)
            if manifest.command.range(of: #"^[a-z][a-z0-9-]*$"#, options: .regularExpression) == nil {
                feature.problem = "“command” must be lowercase letters, digits and dashes."
            } else if BuddyCommands.reserved.contains(manifest.command) {
                feature.problem = "Buddy already has a command called “\(manifest.command)”."
            } else if !feature.script.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") {
                feature.problem = "“run” must be a file inside the feature's folder."
            } else if !FileManager.default.fileExists(atPath: feature.script.path) {
                feature.problem = "The script “\(manifest.run)” is missing."
            } else if FeatureHash.of(folder) == nil {
                feature.problem = "The folder holds a symbolic link (or a file that can't be read); features can't use them."
            }
            return feature
        } catch {
            // Keep a broken feature visible, so the mistake can be found and fixed.
            let manifest = Feature.Manifest(command: id, title: id, summary: "", run: "")
            return Feature(id: id, dir: folder, builtIn: builtIn, manifest: manifest, problem: "feature.json can't be read: \(describe(error))")
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error as? DecodingError {
        case let .keyNotFound(key, _): return "“\(key.stringValue)” is missing."
        case let .typeMismatch(_, context), let .valueNotFound(_, context):
            return "“\(context.codingPath.map(\.stringValue).joined(separator: "."))” has the wrong kind of value."
        case .dataCorrupted: return "it isn't valid JSON."
        default: return error.localizedDescription
        }
    }

    /// The feature that answers to `buddy <command>`: the working one, if two folders claim it.
    static func named(_ command: String) -> Feature? {
        let claimants = all().filter { $0.command == command }
        return claimants.first { $0.problem == nil } ?? claimants.first
    }

    /// The part of Claude's prompt that lists the features that are switched on.
    static func prompt() -> String {
        let lines = all().filter(\.usable).map { f -> String in
            var line = "`buddy \(f.usage)`: \(f.manifest.summary)"
            if let phrases = f.manifest.phrases, !phrases.isEmpty { line += " They might say: " + phrases.map { "\"\($0)\"" }.joined(separator: ", ") + "." }
            if let guidance = f.manifest.guidance, !guidance.isEmpty { line += " " + guidance }
            return "- " + line
        }
        guard !lines.isEmpty else { return "" }
        return """
        \n\nThe user has set up shortcuts for things they do often. When a request matches one, run its \
        command first instead of working it out yourself, then say its result in one sentence (never read \
        out paths, code or compiler output). Each command knows which file, folder and window are in front.
        \(lines.joined(separator: "\n"))
        """
    }

    // MARK: Running

    /// Runs a feature's script and replies with what it printed. The script gets its arguments as given,
    /// anything piped in on stdin, and `BUDDY_*` variables describing what's in front (see `context`).
    static func run(_ feature: Feature, args: [String], stdin: String, reply: @escaping (String) -> Void) {
        let context = self.context()
        guard let expected = feature.expectedHash else { reply("error: \(feature.command) isn't approved"); return }
        DispatchQueue.global(qos: .userInitiated).async {
            // Run a private copy, checked after copying: what runs is exactly what was approved, even if
            // the folder changes while a Touch ID prompt is up or while it runs.
            let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-feature-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: snapshot) }
            guard (try? FileManager.default.copyItem(at: feature.dir, to: snapshot)) != nil, FeatureHash.of(snapshot) == expected else {
                reply("error: “\(feature.manifest.title)” changed since it was approved, so it won't run. Ask the user to approve it again (`buddy feature approve \(feature.command)`).")
                return
            }
            let process = Process()
            let script = snapshot.appendingPathComponent(feature.manifest.run)
            // Executable scripts run by their own #! line; anything else is handed to bash.
            if FileManager.default.isExecutableFile(atPath: script.path) {
                process.executableURL = script
                process.arguments = args
            } else {
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [script.path] + args
            }
            process.currentDirectoryURL = snapshot
            var env = ProcessInfo.processInfo.environment
            let home = NSHomeDirectory()
            env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
            env["BUDDY_FEATURE_DIR"] = snapshot.path
            for (key, value) in Config.featureEnvironment where env[key] == nil { env[key] = value }
            for (key, value) in context { env[key] = value }
            process.environment = env

            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            do { try process.run() } catch {
                reply("error: couldn't start \(feature.manifest.run): \(error.localizedDescription)")
                return
            }
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()

            let limit = feature.manifest.timeout ?? 120
            var timedOut = false
            let timer = DispatchWorkItem { if process.isRunning { timedOut = true; process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: timer)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timer.cancel()

            var text = String(decoding: data.prefix(12_000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if data.count > 12_000 { text += "\n… (output cut off)" }
            if timedOut {
                reply("error: \(feature.command) took longer than \(Int(limit)) seconds and was stopped.\n\(text)")
            } else if process.terminationStatus != 0 && !text.hasPrefix("error") {
                reply("error: \(text.isEmpty ? "\(feature.command) failed (exit \(process.terminationStatus))" : text)")
            } else {
                reply(text.isEmpty ? "ok" : text)
            }
        }
    }

    /// What's in front right now, for scripts:
    ///   BUDDY_FRONT_APP    the app's name ("Code", "Safari")
    ///   BUDDY_FRONT_TITLE  its front window's title
    ///   BUDDY_FRONT_DOC    the file or page that window shows (a path, or a URL in browsers), when the app says
    static func context() -> [String: String] {
        var out: [String: String] = [:]
        guard let app = NSWorkspace.shared.frontmostApplication else { return out }
        out["BUDDY_FRONT_APP"] = app.localizedName ?? ""
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.4)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return out }
        let win = window as! AXUIElement
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &value) == .success, let title = value as? String {
            out["BUDDY_FRONT_TITLE"] = title
        }
        if AXUIElementCopyAttributeValue(win, kAXDocumentAttribute as CFString, &value) == .success, let doc = value as? String {
            out["BUDDY_FRONT_DOC"] = URL(string: doc).flatMap { $0.isFileURL ? $0.path : nil } ?? doc
        } else if let url = pageURL(in: win) {
            out["BUDDY_FRONT_DOC"] = url // Chrome, Arc and other browsers that don't report a document
        }
        return out
    }

    /// The URL of the web page in a browser window: its AXWebArea's AXURL, found breadth-first.
    private static func pageURL(in window: AXUIElement) -> String? {
        var queue = [window], visited = 0
        while !queue.isEmpty, visited < 400 {
            let element = queue.removeFirst()
            visited += 1
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if role as? String == "AXWebArea" {
                var url: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &url) == .success {
                    if let u = url as? URL { return u.absoluteString }
                    if let u = url as? String { return u }
                }
                continue // a page's own contents won't hold another top-level page
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue += list
            }
        }
        return nil
    }

    // MARK: Adding and removing

    /// Makes a new feature folder with a working example to edit. Returns the folder, or an error text.
    static func scaffold(_ name: String) -> Result<URL, FeatureError> {
        let command = name.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !command.isEmpty, command.first?.isLetter == true else { return .failure(.init("A feature's name needs to start with a letter.")) }
        guard !BuddyCommands.reserved.contains(command) else { return .failure(.init("Buddy already has a command called “\(command)”.")) }
        guard !all().contains(where: { $0.id == command || $0.command == command }) else { return .failure(.init("There's already a feature called “\(command)”.")) }
        let dir = userDir.appendingPathComponent(command, isDirectory: true)
        let manifest = Feature.Manifest(command: command, title: name.trimmingCharacters(in: .whitespaces),
                                        summary: "Say what this does in one line.", run: "run.sh", usage: nil,
                                        phrases: ["what you'd say to mean this"], permission: nil, guidance: nil, timeout: nil)
        let script = """
        #!/bin/bash
        # \(command): replace this with what the feature does. Whatever it prints is what Buddy's Claude
        # reads, so print one short line a person could be told out loud. Exit non-zero on failure.
        #
        # What's in front when it runs:
        #   $BUDDY_FRONT_APP    the app's name
        #   $BUDDY_FRONT_TITLE  its window title
        #   $BUDDY_FRONT_DOC    the open file's path (or the page's URL in a browser), when known
        # Arguments after `buddy \(command)` arrive as "$@"; text piped in arrives on stdin.
        # To show a card for something you changed: buddy card "Title" --subtitle "…" --url PATH --kind file

        echo "\(command) ran in front of ${BUDDY_FRONT_APP:-nothing}."
        """
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(manifest).write(to: dir.appendingPathComponent("feature.json"))
            let file = dir.appendingPathComponent("run.sh")
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            // Approved as created (the caller asked for Touch ID). Editing it later needs approving again.
            if let made = all().first(where: { $0.id == command }), let hash = made.hash { Permissions.shared.approve(made.id, hash: hash) }
            return .success(dir)
        } catch {
            return .failure(.init("Couldn't create the folder: \(error.localizedDescription)"))
        }
    }

    /// Moves one of your features to the Trash. Built-in ones can only be switched off.
    static func remove(_ feature: Feature) -> FeatureError? {
        guard !feature.builtIn else { return .init("“\(feature.manifest.title)” is built in: it can be switched off, not removed.") }
        do {
            try FileManager.default.trashItem(at: feature.dir, resultingItemURL: nil)
            Permissions.shared.unpin(feature.id)
            // A built-in feature of the same name takes its place and keeps the level you chose.
            if !all().contains(where: { $0.id == feature.id }) { Permissions.shared.forget(feature.permissionID) }
            return nil
        } catch {
            return .init("Couldn't move it to the Trash: \(error.localizedDescription)")
        }
    }

    /// Changes whenever the prompt's feature list would: Claude Code is restarted to pick it up.
    static var signature: String { prompt() }
}

struct FeatureError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
