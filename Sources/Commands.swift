import CoreGraphics
import Foundation

// MARK: - The `buddy` command line
//
// Every subcommand of the `buddy` CLI (tools/buddy.swift) is one entry in `BuddyCommands.all`: its
// usage, a one-line description for `buddy help`, and what it does through the running app
// (`CommandHost`, implemented by AppDelegate). The CLI only forwards its arguments over a local socket
// (CommandServer.swift), so adding a capability means adding one entry here. Coordinates are pixels of
// the latest screenshot (from `buddy screenshot`, or the one attached to Claude's message).

/// What the commands can ask of the app.
protocol CommandHost: AnyObject {
    /// Captures the screen under the mouse, saves it as a JPEG and makes it the coordinate reference.
    func commandScreenshot(controls: Bool, reply: @escaping (String) -> Void)
    /// The numbered accessibility controls of the app in front.
    func commandControls(reply: @escaping (String) -> Void)
    /// Runs a step under Buddy's safety rules: harmless ones run, risky ones show the OK card first.
    func commandStep(_ step: Step, reply: @escaping (String) -> Void)
    func commandDraw(_ marks: [Mark], reply: @escaping (String) -> Void)
    func commandPoint(_ p: CGPoint, label: String?, reply: @escaping (String) -> Void)
    /// Waits until the screen stops changing (at most `seconds`).
    func commandWait(_ seconds: Double, reply: @escaping (String) -> Void)
    /// Writes Markdown and LaTeX into the chat panel, under the current answer.
    func commandBoard(_ text: String, reply: @escaping (String) -> Void)
    /// Shows cards for what a task changed, under the current answer (and keeps them in the chat log).
    func commandCards(_ cards: [ResultCard], reply: @escaping (String) -> Void)
    /// Asks for the user's OK (Touch ID) before something that always needs it; runs `approved` on yes,
    /// replies "declined: …" on no.
    func commandApproval(prompt: String, spoken: String, approved: @escaping () -> Void, reply: @escaping (String) -> Void)
    /// A feature was added or removed, or a level changed: refresh the Settings window and Claude's prompt.
    func commandSettingsChanged()
    /// Opens the Settings window on "features" or "permissions".
    func commandShowSettings(_ section: String)
}

struct BuddyCommand {
    /// When the user is asked first. Shown in `buddy help`.
    enum Permission {
        case never   // looking, drawing, opening, reading files
        case ifRisky // input on the screen: asks for deleting, sending, paying… (or --confirm)
        case always  // asks with Touch ID every time
    }

    /// One word, or two for a group: "obsidian publish".
    let name: String
    let usage: String
    let summary: String
    var permission: Permission = .never
    /// The row on the Permissions screen that governs it (`Permissions.areas`); nil always runs.
    var area: String? = nil
    let run: (CommandArgs, CommandHost, @escaping (String) -> Void) -> Void
}

/// Parsed arguments: positionals, `--flag value` options and bare `--switch`es.
struct CommandArgs {
    var positional: [String] = []
    var options: [String: String] = [:]
    var switches: Set<String> = []
    /// Text piped into the command (for long notes and boards).
    var stdin = ""

    private static let valued: Set<String> = ["label", "color", "kind", "subtitle", "url"]

    /// The arguments exactly as typed, for feature scripts.
    var raw: [String] = []

    init(_ args: [String], stdin: String) {
        self.stdin = stdin
        raw = args
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--"), a.count > 2 {
                let key = String(a.dropFirst(2))
                if Self.valued.contains(key), i + 1 < args.count { options[key] = args[i + 1]; i += 1 } else { switches.insert(key) }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func number(_ i: Int) -> Double? { i < positional.count ? Double(positional[i]) : nil }
    func numbers(_ count: Int) -> [Double]? {
        let n = (0..<count).compactMap(number)
        return n.count == count ? n : nil
    }
    /// Positionals from `i` on as one text, or what was piped in.
    func text(from i: Int) -> String {
        let joined = i < positional.count ? positional[i...].joined(separator: " ") : ""
        return joined.isEmpty ? stdin.trimmingCharacters(in: .whitespacesAndNewlines) : joined
    }
    var label: String? { options["label"] }
    var color: String? { options["color"] }
    /// --safe and --confirm work like a reply tag's |safe and |confirm.
    func step(_ action: BuddyAction) -> Step {
        Step(action: action, markedSafe: switches.contains("safe"), markedRisky: switches.contains("confirm"))
    }
}

enum BuddyCommands {
    static func run(_ argv: [String], stdin: String, host: CommandHost, reply: @escaping (String) -> Void) {
        guard let name = argv.first, name != "help", name != "--help", name != "-h" else { reply(help); return }
        // Two-word commands ("obsidian publish") before one-word ones.
        let twoWords = argv.count > 1 ? "\(name) \(argv[1])" : ""
        if let command = all.first(where: { $0.name == twoWords }) {
            gate(command, CommandArgs(Array(argv.dropFirst(2)), stdin: stdin), host, reply)
        } else if let command = all.first(where: { $0.name == name }) {
            gate(command, CommandArgs(Array(argv.dropFirst()), stdin: stdin), host, reply)
        } else if let feature = FeatureStore.named(name) {
            run(feature, args: Array(argv.dropFirst()), stdin: stdin, host: host, reply: reply)
        } else {
            let group = all.filter { $0.name.hasPrefix(name + " ") }.map { "buddy " + $0.usage }
            reply(group.isEmpty ? "error: unknown command \"\(name)\". Run `buddy help`."
                                : "error: usage:\n" + group.joined(separator: "\n"))
        }
    }

    static let turnedOff = "is turned off in Buddy's settings. Don't try it another way; tell the user briefly."

    /// Applies the command's row on the Permissions screen before running it.
    private static func gate(_ command: BuddyCommand, _ args: CommandArgs, _ host: CommandHost, _ reply: @escaping (String) -> Void) {
        let level = command.area.map { Permissions.shared.level($0) } ?? .allow
        let title = command.area.flatMap { id in Permissions.areas.first { $0.id == id }?.title } ?? command.name
        // Off stops it here. Asking is done where the step runs (AppDelegate.commandStep), so it happens once.
        if level == .off { reply("error: “\(title)” \(turnedOff)"); return }
        command.run(args, host, reply)
    }

    /// Runs a feature's script: straight away, or after Touch ID when it's set to always ask.
    private static func run(_ feature: Feature, args: [String], stdin: String, host: CommandHost, reply: @escaping (String) -> Void) {
        if let problem = feature.problem { reply("error: the feature “\(feature.id)” can't run. \(problem)"); return }
        guard feature.trusted else {
            reply("error: “\(feature.manifest.title)” is new or has changed since the user approved it, so it won't run. Ask them to approve it with `buddy feature approve \(feature.command)` (Touch ID) or in Settings › Features.")
            return
        }
        let go = { FeatureStore.run(feature, args: args, stdin: stdin, reply: { text in DispatchQueue.main.async { reply(text) } }) }
        switch feature.level {
        case .off: reply("error: “\(feature.manifest.title)” \(turnedOff)")
        case .ask:
            host.commandApproval(prompt: "\(feature.manifest.title)?\nbuddy \(([feature.command] + args).joined(separator: " "))",
                                 spoken: "Can I run \(feature.manifest.title)?", approved: go, reply: reply)
        default: go()
        }
    }

    /// Names a feature can't take.
    static var reserved: Set<String> {
        Set(all.map { $0.name.components(separatedBy: " ")[0] } + ["help"])
    }

    static var help: String {
        let features = FeatureStore.all().filter(\.usable)
        let width = (all.map(\.usage.count) + features.map(\.usage.count)).max() ?? 0
        func row(_ usage: String, _ summary: String) -> String { "  buddy \(usage.padding(toLength: width, withPad: " ", startingAt: 0))  \(summary)" }
        func section(_ title: String, _ permission: BuddyCommand.Permission) -> String {
            title + "\n" + all.filter { $0.permission == permission }.map { row($0.usage, $0.summary) }.joined(separator: "\n")
        }
        var sections = [
            section("Never asks:", .never),
            section("Asks only when risky (deleting, sending, submitting, paying, settings…; add --confirm to make a step ask, --safe to mark a Return harmless):", .ifRisky),
            section("Always asks (Touch ID):", .always),
        ]
        if !features.isEmpty {
            sections.insert("The user's shortcuts (use these first when a request matches; each knows what's in front):\n"
                + features.map { row($0.usage, $0.manifest.summary + ($0.level == .ask ? " (asks first)" : "")) }.joined(separator: "\n"), at: 0)
        }
        return """
        buddy: see and control the screen through the running Buddy app.
        Coordinates are pixels of the latest screenshot (origin top left). When the user is asked, they approve
        with Touch ID; a command they don't approve prints "declined" and exits with code 2.
        The user decides what asks in Settings › Permissions; a command they've turned off prints an error.
        Colors: red (default), blue, green, yellow, orange, purple, pink, teal.
        """ + "\n\n" + sections.joined(separator: "\n\n")
    }

    private static func usageError(_ c: String) -> String { "error: usage: buddy \(all.first { $0.name == c }?.usage ?? c)" }

    static let all: [BuddyCommand] = [
        // Looking
        BuddyCommand(name: "screenshot", usage: "screenshot [--no-controls]",
                     summary: "Save the screen as a JPEG (Read it) and list the front app's controls", area: "screen.look") { a, host, reply in
            host.commandScreenshot(controls: !a.switches.contains("no-controls"), reply: reply)
        },
        BuddyCommand(name: "controls", usage: "controls",
                     summary: "List the front app's controls by number (for press/set)", area: "screen.look") { _, host, reply in
            host.commandControls(reply: reply)
        },

        // Acting
        BuddyCommand(name: "click", usage: "click X Y [--label L] [--double]", summary: "Click a spot", permission: .ifRisky, area: "screen.act") { a, host, reply in
            guard let n = a.numbers(2) else { reply(usageError("click")); return }
            host.commandStep(a.step(.click(CGPoint(x: n[0], y: n[1]), label: a.label, double: a.switches.contains("double"))), reply: reply)
        },
        BuddyCommand(name: "type", usage: "type TEXT", summary: "Type into the focused field (never presses Return)", permission: .ifRisky, area: "screen.act") { a, host, reply in
            let text = a.text(from: 0)
            guard !text.isEmpty else { reply(usageError("type")); return }
            host.commandStep(a.step(.type(text)), reply: reply)
        },
        BuddyCommand(name: "key", usage: "key COMBO", summary: "Press keys, e.g. cmd+t, return, cmd+shift+t", permission: .ifRisky, area: "screen.act") { a, host, reply in
            guard let combo = a.positional.first else { reply(usageError("key")); return }
            host.commandStep(a.step(.key(combo)), reply: reply)
        },
        BuddyCommand(name: "open", usage: "open APP|URL", summary: "Open an app by name, or a link", area: "screen.open") { a, host, reply in
            let target = a.text(from: 0)
            guard !target.isEmpty else { reply(usageError("open")); return }
            host.commandStep(a.step(.open(target)), reply: reply)
        },
        BuddyCommand(name: "scroll", usage: "scroll up|down", summary: "Scroll where the mouse is", area: "screen.act") { a, host, reply in
            host.commandStep(a.step(.scroll(up: a.positional.first?.lowercased() == "up")), reply: reply)
        },
        BuddyCommand(name: "press", usage: "press ID [--label L]", summary: "Press listed control #ID (button, link, checkbox, row…)", permission: .ifRisky, area: "screen.act") { a, host, reply in
            guard let id = a.positional.first.flatMap({ Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) }) else { reply(usageError("press")); return }
            host.commandStep(a.step(.press(id, label: a.label, control: nil)), reply: reply)
        },
        BuddyCommand(name: "set", usage: "set ID TEXT", summary: "Replace the text of listed field #ID", permission: .ifRisky, area: "screen.act") { a, host, reply in
            guard let id = a.positional.first.flatMap({ Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) }) else { reply(usageError("set")); return }
            host.commandStep(a.step(.set(id, text: a.text(from: 1), control: nil)), reply: reply)
        },
        BuddyCommand(name: "menu", usage: "menu \"File>Save As…\"", summary: "Choose a menu-bar command by its path", permission: .ifRisky, area: "screen.act") { a, host, reply in
            let path = a.text(from: 0).components(separatedBy: CharacterSet(charactersIn: ">›"))
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !path.isEmpty else { reply(usageError("menu")); return }
            host.commandStep(a.step(.menu(path)), reply: reply)
        },
        BuddyCommand(name: "wait", usage: "wait [SECONDS]", summary: "Wait until the screen stops changing (max SECONDS, default 3)") { a, host, reply in
            host.commandWait(min(max(a.number(0) ?? 3, 0.5), 15), reply: reply)
        },

        // Showing
        BuddyCommand(name: "point", usage: "point X Y [LABEL]", summary: "Fly the blue cursor buddy to a spot", area: "screen.draw") { a, host, reply in
            guard let n = a.numbers(2) else { reply(usageError("point")); return }
            let label = a.text(from: 2)
            host.commandPoint(CGPoint(x: n[0], y: n[1]), label: label.isEmpty ? a.label : label, reply: reply)
        },
        BuddyCommand(name: "circle", usage: "circle X Y W H [--label L] [--color C]", summary: "Circle something on screen", area: "screen.draw") { a, host, reply in
            guard let n = a.numbers(4) else { reply(usageError("circle")); return }
            host.commandDraw([.circle(CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), label: a.label, color: a.color)], reply: reply)
        },
        BuddyCommand(name: "box", usage: "box X Y W H [--label L] [--color C]", summary: "Draw a rounded box around something", area: "screen.draw") { a, host, reply in
            guard let n = a.numbers(4) else { reply(usageError("box")); return }
            host.commandDraw([.box(CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), label: a.label, color: a.color)], reply: reply)
        },
        BuddyCommand(name: "arrow", usage: "arrow X1 Y1 X2 Y2 [--label L] [--color C]", summary: "Arrow from X1,Y1 pointing at X2,Y2", area: "screen.draw") { a, host, reply in
            guard let n = a.numbers(4) else { reply(usageError("arrow")); return }
            host.commandDraw([.arrow(from: CGPoint(x: n[0], y: n[1]), to: CGPoint(x: n[2], y: n[3]), label: a.label, color: a.color)], reply: reply)
        },
        BuddyCommand(name: "underline", usage: "underline X1 Y X2 [--color C]", summary: "Underline text whose baseline is at Y", area: "screen.draw") { a, host, reply in
            guard let n = a.numbers(3) else { reply(usageError("underline")); return }
            host.commandDraw([.underline(from: CGPoint(x: n[0], y: n[1]), to: CGPoint(x: n[2], y: n[1]), color: a.color)], reply: reply)
        },
        BuddyCommand(name: "highlight", usage: "highlight X Y W H [--color C]", summary: "Highlighter wash over text", area: "screen.draw") { a, host, reply in
            guard let n = a.numbers(4) else { reply(usageError("highlight")); return }
            host.commandDraw([.highlight(CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), color: a.color)], reply: reply)
        },
        BuddyCommand(name: "note", usage: "note X Y TEXT [--color C]", summary: "Small card beside X,Y (Markdown and LaTeX; or pipe the text in)", area: "screen.draw") { a, host, reply in
            guard let n = a.numbers(2) else { reply(usageError("note")); return }
            let text = a.text(from: 2)
            guard !text.isEmpty else { reply(usageError("note")); return }
            host.commandDraw([.note(at: CGPoint(x: n[0], y: n[1]), text: text, color: a.color)], reply: reply)
        },
        BuddyCommand(name: "clear", usage: "clear", summary: "Wipe everything drawn on screen") { _, host, reply in
            host.commandDraw([.clear], reply: reply)
        },
        BuddyCommand(name: "board", usage: "board TEXT", summary: "Write Markdown and LaTeX into the chat panel (or pipe the text in)") { a, host, reply in
            let text = a.text(from: 0)
            guard !text.isEmpty else { reply(usageError("board")); return }
            host.commandBoard(text, reply: reply)
        },

        BuddyCommand(name: "card", usage: "card TITLE [--subtitle S] [--url URL|PATH] [--kind K]",
                     summary: "Show a card for something a task changed; clicking opens it (kinds: note, calendar, file, email, task, link)") { a, host, reply in
            let title = a.text(from: 0)
            guard !title.isEmpty else { reply(usageError("card")); return }
            host.commandCards([ResultCard(kind: a.options["kind"]?.lowercased() ?? "link", title: title,
                                          subtitle: a.options["subtitle"], url: a.options["url"])], reply: reply)
        },

        // Files
        BuddyCommand(name: "files", usage: "files [DIR]", summary: "List a folder (default: home), folders first") { a, _, reply in
            reply(Files.list(a.text(from: 0)))
        },
        BuddyCommand(name: "read", usage: "read FILE", summary: "Print a text file (up to 200 KB)") { a, _, reply in
            let path = a.text(from: 0)
            guard !path.isEmpty else { reply(usageError("read")); return }
            reply(Files.read(path))
        },

        // Obsidian
        BuddyCommand(name: "obsidian publish", usage: "obsidian publish [NOTE]",
                     summary: "Make NOTE public (if given), then publish the vault's public notes to the site",
                     permission: .always, area: "connector.obsidian") { a, host, reply in
            let query = a.text(from: 0)
            var note: URL?
            if !query.isEmpty {
                guard let found = ObsidianPublisher.findNote(query) else { reply("error: no note matching \"\(query)\" in the vault"); return }
                note = found
            }
            let title = note.map { $0.deletingPathExtension().lastPathComponent }
            host.commandApproval(
                prompt: title.map { "Publish “\($0)” to your site?" } ?? "Publish your public Obsidian notes to your site?",
                spoken: title.map { "Can I publish \($0) to your site?" } ?? "Can I publish your notes to your site?",
                approved: {
                    ObsidianPublisher.publish(making: note) { text, cards in
                        DispatchQueue.main.async {
                            if cards.isEmpty { reply(text) } else { host.commandCards(cards) { _ in reply(text) } }
                        }
                    }
                },
                reply: reply)
        },

        // Features and permissions (the Settings window does the same things)
        BuddyCommand(name: "features", usage: "features", summary: "List the user's features (shortcuts), where they live and whether each is on") { _, _, reply in
            let rows = FeatureStore.all().map { f -> String in
                let state = f.problem.map { "BROKEN: \($0)" } ?? (f.trusted ? f.level.title.lowercased() : "NOT APPROVED (new or changed; `buddy feature approve \(f.command)`)")
                return "\(f.command)\t\(state)\t\(f.builtIn ? "built in" : "yours")\t\(f.manifest.summary)\n    \(f.dir.path)"
            }
            reply("""
            A feature is a folder with feature.json and a script; the guide is features/README.md in Buddy's repo.
            Yours: \(FeatureStore.userDir.path)
            Built in: \(FeatureStore.builtInDir?.path ?? "none")

            """ + (rows.isEmpty ? "No features yet." : rows.joined(separator: "\n")))
        },
        BuddyCommand(name: "feature new", usage: "feature new NAME", summary: "Make a new feature folder with an example to edit, and print its path",
                     permission: .always) { a, host, reply in
            let name = a.text(from: 0)
            guard !name.isEmpty else { reply(usageError("feature new")); return }
            host.commandApproval(prompt: "Add a feature called “\(name)”?", spoken: "Can I add a feature called \(name)?", approved: {
                switch FeatureStore.scaffold(name) {
                case let .success(dir):
                    host.commandSettingsChanged()
                    reply("ok: created \(dir.path). Edit feature.json and run.sh there; once edited it needs `buddy feature approve \(dir.lastPathComponent)` before it runs, and it asks before each run until the user changes its level.")
                case let .failure(error): reply("error: \(error.message)")
                }
            }, reply: reply)
        },
        BuddyCommand(name: "feature approve", usage: "feature approve NAME", summary: "Ask the user to approve a new or edited feature so it can run",
                     permission: .always) { a, host, reply in
            guard let feature = FeatureStore.all().first(where: { $0.command == a.text(from: 0) || $0.id == a.text(from: 0) }) else {
                reply("error: no feature called “\(a.text(from: 0))”. Run `buddy features`."); return
            }
            if let problem = feature.problem { reply("error: fix it first: \(problem)"); return }
            if feature.trusted { reply("ok: \(feature.command) is already approved"); return }
            guard let hash = feature.hash else { reply("error: its folder can't be read"); return } // what the user is shown is what gets approved
            host.commandApproval(prompt: "Approve the feature “\(feature.manifest.title)”?\n\(feature.dir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))",
                                 spoken: "Can I turn on the feature \(feature.manifest.title)?", approved: {
                guard FeatureStore.all().first(where: { $0.id == feature.id })?.hash == hash else { reply("error: it changed while waiting; approve it again"); return }
                Permissions.shared.approve(feature.id, hash: hash)
                host.commandSettingsChanged()
                reply("ok: approved \(feature.command)")
            }, reply: reply)
        },
        BuddyCommand(name: "feature remove", usage: "feature remove NAME", summary: "Move one of the user's features to the Trash",
                     permission: .always) { a, host, reply in
            guard let feature = FeatureStore.all().first(where: { $0.command == a.text(from: 0) || $0.id == a.text(from: 0) }) else {
                reply("error: no feature called “\(a.text(from: 0))”. Run `buddy features`."); return
            }
            host.commandApproval(prompt: "Remove the feature “\(feature.manifest.title)”?", spoken: "Can I remove \(feature.manifest.title)?", approved: {
                if let error = FeatureStore.remove(feature) { reply("error: \(error.message)"); return }
                host.commandSettingsChanged()
                reply("ok: moved \(feature.id) to the Trash")
            }, reply: reply)
        },
        BuddyCommand(name: "permissions", usage: "permissions", summary: "List what Buddy may do and when it asks") { _, _, reply in
            var out: [String] = []
            for group in ["Your screen", "Your Mac", "Connectors"] {
                out.append(group + ":")
                for area in Permissions.areas where area.group == group {
                    out.append("  \(area.id.padding(toLength: 20, withPad: " ", startingAt: 0)) \(Permissions.shared.level(area.id).rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) \(area.title) (can be: \(area.levels.map(\.rawValue).joined(separator: ", ")))")
                }
            }
            out.append("Features (can be: off, ask, allow):")
            for f in FeatureStore.all() {
                out.append("  \(f.permissionID.padding(toLength: 20, withPad: " ", startingAt: 0)) \(f.level.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) \(f.manifest.title)")
            }
            out.append("Always: " + Permissions.fixed.map { "\($0.title): \($0.level)" }.joined(separator: "; ") + ".")
            out.append("Levels: off = never; ask = asks every time; risky = asks before changes; allow = never asks.")
            reply(out.joined(separator: "\n"))
        },
        BuddyCommand(name: "permission", usage: "permission ID LEVEL", summary: "Set a level from `buddy permissions` (asks with Touch ID when it loosens one)",
                     permission: .always) { a, host, reply in
            guard a.positional.count == 2, let level = Level(rawValue: a.positional[1].lowercased()) else { reply(usageError("permission")); return }
            let id = a.positional[0]
            let feature = FeatureStore.all().first { $0.permissionID == id || "feature.\($0.command)" == id || (!id.contains(".") && $0.command == id) }
            let key = feature?.permissionID ?? id
            guard feature != nil || Permissions.areas.contains(where: { $0.id == id }) else { reply("error: no permission called “\(id)”. Run `buddy permissions`."); return }
            guard Permissions.shared.accepts(key, level) else { reply("error: “\(id)” can't be set to \(level.rawValue). Run `buddy permissions`."); return }
            let title = feature?.manifest.title ?? Permissions.areas.first { $0.id == id }?.title ?? id
            let apply = {
                Permissions.shared.set(key, level)
                host.commandSettingsChanged()
                reply("ok: \(title) is now “\(level.title)”")
            }
            // Asking more is always fine; asking less needs the user's fingerprint.
            guard Permissions.shared.loosens(key, to: level, fallback: feature?.defaultLevel) else { apply(); return }
            host.commandApproval(prompt: "Change “\(title)” to “\(level.title)”?", spoken: "Can I change the permission for \(title)?", approved: apply, reply: reply)
        },
        BuddyCommand(name: "settings", usage: "settings [features|permissions]", summary: "Open Buddy's Settings window") { a, host, reply in
            host.commandShowSettings(a.positional.first?.lowercased() == "permissions" ? "permissions" : "features")
            reply("ok: opened Settings")
        },
    ]
}
