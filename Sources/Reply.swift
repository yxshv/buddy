import CoreGraphics
import Foundation

/// Something Buddy can do on the computer once the user confirms it.
enum BuddyAction {
    case click(CGPoint, label: String?, double: Bool)
    case type(String)
    case key(String)
    case open(String)
    case scroll(up: Bool)
    case wait(Double)
    // By accessibility, on a control from the numbered list (`control` is filled in once resolved).
    case press(Int, label: String?, control: AXControl?)
    case set(Int, text: String, control: AXControl?)
    case menu([String])

    var target: CGPoint? {
        switch self {
        case let .click(p, _, _): return p
        case let .press(_, _, c), let .set(_, _, c): return c?.center
        default: return nil
        }
    }

    /// What the control is called: its real accessibility label, else what Claude called it.
    var name: String? {
        switch self {
        case let .click(_, label, _): return label
        case let .press(_, label, c): return c?.label ?? label
        case let .set(_, _, c): return c?.label
        case let .menu(path): return path.last
        default: return nil
        }
    }

    /// Everything the safety checks should look at: Claude's label and the control's real one.
    var riskText: String {
        switch self {
        case let .press(_, label, c): return [c?.label, label].compactMap { $0 }.joined(separator: " ")
        case let .menu(path): return path.joined(separator: " ")
        default: return name ?? ""
        }
    }

    private var quotedName: String { name.map { " “\($0)”" } ?? "" }
    private static func short(_ text: String, _ n: Int) -> String { text.count > n ? text.prefix(n) + "…" : text }

    /// The confirmation question.
    var prompt: String {
        switch self {
        case let .click(_, label, double): return "\(double ? "Double-click" : "Click") \(label.map { "“\($0)”" } ?? "here")?"
        case let .type(text): return "Type “\(text.count > 60 ? text.prefix(60) + "…" : text)”?"
        case let .key(combo): return "Press \(combo)?"
        case let .open(thing): return "Open \(thing)?"
        case let .scroll(up): return "Scroll \(up ? "up" : "down")?"
        case .wait: return "Wait a moment?"
        case .press: return "Click \(name.map { "“\($0)”" } ?? "this")?"
        case let .set(_, text, _): return "Type “\(Self.short(text, 60))”\(name.map { " into “\($0)”" } ?? "")?"
        case let .menu(path): return "Choose \(path.joined(separator: " › "))?"
        }
    }

    /// The question Buddy says out loud before a risky step.
    var spoken: String {
        switch self {
        case let .click(_, label, double): return "Should I \(double ? "double-click" : "click") \(label ?? "there")?"
        case .type: return "Should I type that in?"
        case let .key(combo): return "Should I press \(Self.speakable(combo))?"
        case let .open(thing): return "Should I open \(thing)?"
        case let .scroll(up): return "Should I scroll \(up ? "up" : "down")?"
        case .wait: return "Should I wait?"
        case .press: return "Should I click \(name ?? "that")?"
        case .set: return "Should I type that in?"
        case .menu: return "Should I choose \(name ?? "that")?"
        }
    }

    private static func speakable(_ combo: String) -> String {
        let names = ["cmd": "Command", "command": "Command", "shift": "Shift", "opt": "Option", "option": "Option",
                     "alt": "Option", "ctrl": "Control", "control": "Control", "delete": "Delete", "backspace": "Delete",
                     "return": "Return", "enter": "Return", "esc": "Escape", "escape": "Escape", "tab": "Tab", "space": "Space"]
        return combo.split(separator: "+").map { part in
            let key = part.trimmingCharacters(in: .whitespaces).lowercased()
            return names[key] ?? key.uppercased()
        }.joined(separator: " ")
    }

    /// What happened, reported back to Claude.
    var done: String {
        switch self {
        case let .click(_, label, double): return "\(double ? "double-clicked" : "clicked") \(label ?? "the spot")"
        case let .type(text): return "typed \"\(text)\""
        case let .key(combo): return "pressed \(combo)"
        case let .open(thing): return "opened \(thing)"
        case let .scroll(up): return "scrolled \(up ? "up" : "down")"
        case let .wait(s): return "waited \(Int(s.rounded())) seconds"
        case let .press(id, _, _): return "pressed #\(id)\(quotedName)"
        case let .set(id, text, _): return "typed \"\(text)\" into #\(id)\(quotedName)"
        case let .menu(path): return "chose \(path.joined(separator: " > "))"
        }
    }

    /// Shown while it runs without asking.
    var doing: String {
        switch self {
        case let .click(_, label, _): return "Clicking \(label.map { "“\($0)”" } ?? "")…"
        case let .type(text): return "Typing “\(text.count > 40 ? text.prefix(40) + "…" : text)”…"
        case let .key(combo): return "Pressing \(combo)…"
        case let .open(thing): return "Opening \(thing)…"
        case let .scroll(up): return "Scrolling \(up ? "up" : "down")…"
        case .wait: return "Waiting for it to load…"
        case .press: return "Clicking\(quotedName)…"
        case let .set(_, text, _): return "Typing “\(Self.short(text, 40))”…"
        case .menu: return "Choosing\(quotedName)…"
        }
    }

    /// Opening things goes through NSWorkspace; everything else posts input events.
    var needsAccessibility: Bool {
        switch self {
        case .open, .wait: return false
        default: return true
        }
    }

    func mapped(_ f: (CGPoint) -> CGPoint) -> BuddyAction {
        if case let .click(p, label, double) = self { return .click(f(p), label: label, double: double) }
        return self
    }

    /// Attaches the numbered control from the list sent with this turn.
    func resolved(_ snapshot: AXSnapshot?) -> BuddyAction {
        switch self {
        case let .press(id, label, nil): return .press(id, label: label, control: snapshot?.controls[id])
        case let .set(id, text, nil): return .set(id, text: text, control: snapshot?.controls[id])
        default: return self
        }
    }
}

/// A proposed action plus whether Claude marked it harmless (`|safe`).
struct Step {
    var action: BuddyAction
    var markedSafe: Bool
    var markedRisky = false // Claude added |confirm

    /// Everyday, undoable steps run straight away. Anything that deletes, sends, submits, pays, shares or
    /// changes settings asks first: when Claude marks it |confirm, and always for risky keys and buttons.
    var runsWithoutAsking: Bool {
        if markedRisky { return false }
        switch action {
        case .open, .scroll, .wait: return true
        // Return can send a chat message, so it needs a |safe mark (or a search box) unless it's plain navigation.
        case let .key(combo): return Self.navigationKeys.contains(Self.normalize(combo)) || (markedSafe && !Self.isRiskyKey(combo))
        // Typing a name, search or URL changes nothing by itself (sending is a separate, guarded step);
        // long or multi-line text, like a whole message, asks first.
        case let .type(text): return markedSafe || (text.count <= 80 && !text.contains("\n"))
        case .click, .press:
            let label = action.riskText
            guard !label.isEmpty else { return markedSafe }
            return !Self.isRiskyButton(label)
        case let .set(_, text, _): return markedSafe || (text.count <= 80 && !text.contains("\n"))
        case .menu: return !Self.isRiskyButton(action.riskText) && !Self.isRiskyMenu(action.riskText)
        }
    }

    func mapped(_ f: (CGPoint) -> CGPoint) -> Step { Step(action: action.mapped(f), markedSafe: markedSafe, markedRisky: markedRisky) }
    func resolved(_ snapshot: AXSnapshot?) -> Step { Step(action: action.resolved(snapshot), markedSafe: markedSafe, markedRisky: markedRisky) }

    /// The row on Settings › Permissions this step falls under.
    var area: String {
        if case .open = action { return "screen.open" }
        return "screen.act"
    }

    /// What Settings › Permissions says about this kind of step.
    var level: Level {
        if case .wait = action { return .allow }
        return Permissions.shared.level(area)
    }

    /// Steps that destroy something or spend money: these ask every time, even after you've OK'd
    /// another step in the same task.
    var isDestructive: Bool {
        switch action {
        case .click, .press, .menu:
            return action.riskText.range(of: #"\b(delete|remove|trash|erase|empty|discard|overwrite|format|uninstall|pay|buy|purchase|order|checkout|check out|transfer)\b"#,
                                options: [.regularExpression, .caseInsensitive]) != nil
        case let .key(combo): return Self.isRiskyKey(combo) && Self.normalize(combo).contains("delete")
        default: return false
        }
    }

    /// Buttons that delete, send, pay or otherwise can't be taken back always ask, whatever Claude says.
    private static func isRiskyButton(_ label: String) -> Bool {
        label.range(of: #"\b(delete|remove|send|submit|pay|buy|purchase|order|checkout|check out|publish|post|share|confirm|trash|erase|sign ?out|log ?out|uninstall|install|discard|unsubscribe|transfer|reset|format|block|report|accept|agree|allow|empty|overwrite|replace)\b"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Menu commands that close, quit or save, like their risky shortcuts.
    private static func isRiskyMenu(_ text: String) -> Bool {
        text.range(of: #"\b(quit|close|save|revert|restart|shut ?down|force quit)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Keys that only move around or open something new.
    private static let navigationKeys: Set<String> = [
        "cmd+t", "cmd+n", "cmd+l", "cmd+f", "cmd+tab", "cmd+space", "cmd+[", "cmd+]", "cmd+shift+t",
        "tab", "shift+tab", "escape", "esc", "up", "down", "left", "right", "pageup", "pagedown", "home", "end", "space",
    ]

    /// Keys that delete, undo, cut, save, close or quit: always confirmed, whatever Claude says.
    private static func isRiskyKey(_ combo: String) -> Bool {
        let parts = Set(normalize(combo).split(separator: "+").map(String.init))
        if !parts.isDisjoint(with: ["delete", "backspace", "forwarddelete"]) { return true }
        return parts.contains("cmd") && !parts.isDisjoint(with: ["x", "z", "s", "w", "q", "v", "a"])
    }

    private static func normalize(_ combo: String) -> String {
        let order = ["cmd": 0, "ctrl": 1, "option": 2, "shift": 3]
        let aliases = ["command": "cmd", "⌘": "cmd", "control": "ctrl", "⌃": "ctrl", "opt": "option", "alt": "option", "⌥": "option", "⇧": "shift"]
        return combo.lowercased().split(separator: "+")
            .map { p -> String in let s = p.trimmingCharacters(in: .whitespaces); return aliases[s] ?? s }
            .sorted { (order[$0] ?? 9) < (order[$1] ?? 9) }
            .joined(separator: "+")
    }
}

/// Something Buddy draws on the screen canvas. Coordinates are screenshot pixels (origin top-left).
enum Mark {
    case arrow(from: CGPoint, to: CGPoint, label: String?, color: String?)
    case circle(CGRect, label: String?, color: String?)
    case box(CGRect, label: String?, color: String?)
    case underline(from: CGPoint, to: CGPoint, color: String?)
    case highlight(CGRect, color: String?)
    case note(at: CGPoint?, text: String, color: String?)
    case board(at: CGPoint?, width: Double?, text: String)
    case clear
}

/// Splits streamed text into speakable sentences and pulls out [POINT:…], action and drawing tags.
final class ReplyParser {
    struct Point { let x: Double; let y: Double; let label: String? }

    /// One sentence's worth of reply.
    struct Chunk {
        var text = ""
        var points: [Point] = []
        var actions: [Step] = []
        var marks: [Mark] = []
        var ends = false // [END]: the user is wrapping up, don't listen for a follow-up
    }

    private var buffer = ""
    /// After clicking a search or address box and typing, Return just submits that search: it's harmless.
    private var inSearchBox = false
    private let onChunk: (Chunk) -> Void
    private static let tag = try! NSRegularExpression(
        pattern: #"\[(POINT|CLICK|DOUBLECLICK|PRESS|SET|MENU|TYPE|KEY|OPEN|SCROLL|WAIT|ARROW|CIRCLE|BOX|UNDERLINE|HIGHLIGHT|CLEAR|END)(?::([^\]]*))?\]"#)
    /// NOTE and BOARD wrap free text (Markdown and LaTeX, which may contain brackets).
    private static let block = try! NSRegularExpression(
        pattern: #"\[(NOTE|BOARD)(?::([^\]]*))?\]([\s\S]*?)(?:\[/\1\]|$)"#)
    private static let blockStarts = ["[NOTE", "[BOARD"]
    private static let coords = try! NSRegularExpression(pattern: #"^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*(?::\s*(.*))?$"#)
    private static let colors: Set<String> = ["red", "blue", "green", "yellow", "orange", "purple", "pink", "teal"]

    init(onChunk: @escaping (Chunk) -> Void) { self.onChunk = onChunk }

    func reset() {
        buffer = ""
        inSearchBox = false
    }

    func feed(_ text: String) {
        buffer += text
        drain(final: false)
    }

    func finish() { drain(final: true) }

    private func drain(final: Bool) {
        while let cut = boundary() {
            emit(String(buffer[..<cut]))
            buffer = String(buffer[cut...])
        }
        if final {
            emit(buffer)
            buffer = ""
        }
    }

    /// End of the first complete sentence, never inside an unfinished [tag] or NOTE/BOARD block.
    private func boundary() -> String.Index? {
        var depth = 0
        var i = buffer.startIndex
        while i < buffer.endIndex {
            let c = buffer[i]
            var next = buffer.index(after: i)
            if c == "[", depth == 0, let opener = Self.blockStarts.first(where: { buffer[i...].hasPrefix($0) }) {
                // Skip the whole block; until its closing tag arrives, nothing after it can be cut.
                guard let close = buffer.range(of: "[/" + opener.dropFirst() + "]", range: i..<buffer.endIndex) else { return nil }
                next = close.upperBound
            } else if c == "[" { depth += 1 }
            else if c == "]" { depth = max(0, depth - 1) }
            else if depth == 0 {
                if c == "\n" { return next }
                if ".!?".contains(c), next < buffer.endIndex, buffer[next].isWhitespace { return next }
            }
            i = next
        }
        return nil
    }

    private func emit(_ input: String) {
        var chunk = Chunk()

        // Blocks first: their text goes on the canvas and is never read aloud.
        var ns = input as NSString
        for m in Self.block.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            let (body, _, color) = Self.split(m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2)))
            let text = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let (n, _) = Self.numbers(body)
            if ns.substring(with: m.range(at: 1)) == "NOTE" {
                chunk.marks.append(.note(at: n.count >= 2 ? CGPoint(x: n[0], y: n[1]) : nil, text: text, color: color))
            } else {
                chunk.marks.append(.board(at: n.count >= 2 ? CGPoint(x: n[0], y: n[1]) : nil,
                                          width: n.count == 3 ? n[2] : n.count == 1 ? n[0] : nil, text: text))
            }
        }
        let raw = Self.block.stringByReplacingMatches(in: input, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        ns = raw as NSString
        let all = NSRange(location: 0, length: ns.length)

        for m in Self.tag.matches(in: raw, range: all) {
            let kind = ns.substring(with: m.range(at: 1))
            let (body, flag, color) = Self.split(m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2)))
            let safe = flag == "safe", risky = flag == "confirm"
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            let add = { (a: BuddyAction) in
                var markedSafe = safe
                switch a {
                case .click, .press:
                    self.inSearchBox = a.name?.range(of: "search|address|url|find|query", options: [.regularExpression, .caseInsensitive]) != nil
                case .type, .set:
                    break
                case let .key(combo) where self.inSearchBox && ["return", "enter"].contains(combo.lowercased()):
                    markedSafe = true
                    self.inSearchBox = false
                default:
                    self.inSearchBox = false
                }
                chunk.actions.append(Step(action: a, markedSafe: markedSafe, markedRisky: risky))
            }
            let (n, label) = Self.numbers(body)
            switch kind {
            case "POINT", "CLICK", "DOUBLECLICK":
                guard let (p, label) = Self.parseCoords(body) else { continue }
                if kind == "POINT" { chunk.points.append(Point(x: p.x, y: p.y, label: label)) }
                else { add(.click(p, label: label, double: kind == "DOUBLECLICK")) }
            case "PRESS":
                let parts = body.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard let id = parts.first.flatMap({ Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) }) else { continue }
                add(.press(id, label: parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil, control: nil))
            case "SET":
                let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, let id = Int(parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "# "))) else { continue }
                add(.set(id, text: String(parts[1]), control: nil))
            case "MENU":
                let path = trimmed.components(separatedBy: CharacterSet(charactersIn: ">›")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !path.isEmpty { add(.menu(path)) }
            case "TYPE": if !body.isEmpty { add(.type(body)) }
            case "KEY": if !trimmed.isEmpty { add(.key(trimmed)) }
            case "OPEN": if !trimmed.isEmpty { add(.open(trimmed)) }
            case "SCROLL": add(.scroll(up: trimmed.lowercased().hasPrefix("up")))
            case "WAIT": add(.wait(min(max(Double(trimmed) ?? 2, 0.5), 8)))
            case "ARROW" where n.count >= 4:
                chunk.marks.append(.arrow(from: CGPoint(x: n[0], y: n[1]), to: CGPoint(x: n[2], y: n[3]), label: label, color: color))
            case "CIRCLE" where n.count >= 4: chunk.marks.append(.circle(CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), label: label, color: color))
            case "CIRCLE" where n.count == 3: // center and radius
                chunk.marks.append(.circle(CGRect(x: n[0] - n[2], y: n[1] - n[2], width: n[2] * 2, height: n[2] * 2), label: label, color: color))
            case "BOX" where n.count >= 4: chunk.marks.append(.box(CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), label: label, color: color))
            case "UNDERLINE" where n.count >= 4: chunk.marks.append(.underline(from: CGPoint(x: n[0], y: n[1]), to: CGPoint(x: n[2], y: n[3]), color: color))
            case "UNDERLINE" where n.count == 3: chunk.marks.append(.underline(from: CGPoint(x: n[0], y: n[1]), to: CGPoint(x: n[2], y: n[1]), color: color))
            case "HIGHLIGHT" where n.count >= 4: chunk.marks.append(.highlight(CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), color: color))
            case "CLEAR": chunk.marks.append(.clear)
            case "END": chunk.ends = true
            default: break
            }
        }

        var text = Self.tag.stringByReplacingMatches(in: raw, range: all, withTemplate: "")
        // A block still streaming in at the very end, or a stray closing tag, is never spoken.
        text = text.replacingOccurrences(of: #"\[/?(NOTE|BOARD)[^\]]*\]?"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "[*`#]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        chunk.text = text
        if !text.isEmpty || !chunk.points.isEmpty || !chunk.actions.isEmpty || !chunk.marks.isEmpty || chunk.ends { onChunk(chunk) }
    }

    /// Splits trailing `|safe`, `|confirm` and `|blue`-style marks off a tag body.
    private static func split(_ body: String) -> (body: String, flag: String?, color: String?) {
        var body = body, flag: String?, color: String?
        while let bar = body.lastIndex(of: "|") {
            let word = body[body.index(after: bar)...].trimmingCharacters(in: .whitespaces).lowercased()
            if word == "safe" || word == "confirm" { flag = word }
            else if colors.contains(word) { color = word }
            else { break }
            body = String(body[..<bar])
        }
        return (body, flag, color)
    }

    /// "x1,y1,x2,y2:label" → numbers and label.
    private static func numbers(_ body: String) -> ([Double], String?) {
        let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let nums = (parts.first ?? "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        let label = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        return (nums, label.isEmpty ? nil : label)
    }

    private static func parseCoords(_ body: String) -> (CGPoint, String?)? {
        let ns = body as NSString
        guard let m = coords.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)),
              let x = Double(ns.substring(with: m.range(at: 1))),
              let y = Double(ns.substring(with: m.range(at: 2))) else { return nil }
        let label = m.range(at: 3).location == NSNotFound ? nil
            : ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
        return (CGPoint(x: x, y: y), label?.isEmpty == true ? nil : label)
    }
}
