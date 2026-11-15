import AppKit
import ApplicationServices

/// Performs confirmed actions: accessibility actions on listed controls, or synthetic input events.
/// Needs Accessibility permission.
enum Executor {
    /// True when Buddy may post input events; otherwise shows the system prompt to grant it.
    static func ensureTrusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        return false
    }

    /// Runs the action; returns what went wrong, for Claude, when it couldn't be done.
    static func run(_ action: BuddyAction) -> String? {
        switch action {
        case let .click(p, _, double): click(at: p, double: double)
        case let .type(text): type(text)
        case let .key(combo): press(combo)
        case let .open(thing): open(thing)
        case let .scroll(up): scroll(up: up)
        case .wait: break // the pause itself happens before the next screenshot
        case let .press(id, _, control):
            guard let control else { return "#\(id) isn't in the latest list" }
            return press(control)
        case let .set(id, text, control):
            guard let control else { return "#\(id) isn't in the latest list" }
            return set(control, to: text)
        case let .menu(path): return choose(path)
        }
        return nil
    }

    // MARK: Accessibility actions

    private static func press(_ c: AXControl) -> String? {
        let actions = actionNames(c.element)
        if actions.contains(kAXPressAction as String), AXUIElementPerformAction(c.element, kAXPressAction as CFString) == .success { return nil }
        // Rows and cells select rather than press.
        if c.role == "AXRow" || c.role == "AXCell",
           AXUIElementSetAttributeValue(c.element, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success { return nil }
        if AXTree.editable(c.role), focus(c) { return nil }
        for name in [kAXConfirmAction, kAXPickAction, kAXShowMenuAction] as [String] where actions.contains(name) {
            if AXUIElementPerformAction(c.element, name as CFString) == .success { return nil }
        }
        // No accessibility action: fall back to a real click at its center.
        guard let center = AXTree.frame(of: c.element).map({ CGPoint(x: $0.midX, y: $0.midY) }) ?? c.center else {
            return "couldn't press #\(c.label ?? "it")"
        }
        click(at: center, double: false)
        return nil
    }

    /// Replaces a field's text: focus it, select all, paste. Pasting (rather than setting the value)
    /// lets web pages and search fields react as if it were typed.
    private static func set(_ c: AXControl, to text: String) -> String? {
        if !focus(c) {
            guard let center = AXTree.frame(of: c.element).map({ CGPoint(x: $0.midX, y: $0.midY) }) ?? c.center else {
                return "couldn't reach the \(c.label ?? "field")"
            }
            click(at: center, double: false)
            usleep(150_000)
            // Never select-all and paste unless the field really has focus: that could overwrite a document.
            guard isFocused(c) else { return "couldn't focus the \(c.label ?? "field")" }
        }
        usleep(60_000)
        press("cmd+a")
        usleep(40_000)
        type(text)
        return nil
    }

    private static func focus(_ c: AXControl) -> Bool {
        if isFocused(c) { return true }
        AXUIElementSetAttributeValue(c.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        for _ in 0..<5 {
            if isFocused(c) { return true }
            usleep(40_000)
        }
        return false
    }

    private static func isFocused(_ c: AXControl) -> Bool {
        guard let app = AXTree.frontApp else { return false }
        let focused: AXUIElement? = AXTree.attr(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute)
        guard let focused else { return (AXTree.attr(c.element, kAXFocusedAttribute) as Bool?) == true }
        return CFEqual(focused, c.element) || (AXTree.attr(c.element, kAXFocusedAttribute) as Bool?) == true
    }

    /// Chooses a menu-bar command by its path, e.g. ["File", "Save As…"]. Works with the menu closed.
    private static func choose(_ path: [String]) -> String? {
        guard let app = AXTree.frontApp else { return "no app is in front" }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        guard var level: AXUIElement = AXTree.attr(appEl, kAXMenuBarAttribute) else { return "\(app.localizedName ?? "the app") has no menu bar" }
        for (i, name) in path.enumerated() {
            var items: [AXUIElement] = AXTree.attr(level, kAXChildrenAttribute) ?? []
            // Menu-bar items and submenu items hold their menu as a single AXMenu child.
            if items.count == 1, (AXTree.attr(items[0], kAXRoleAttribute) as String?) == "AXMenu" {
                items = AXTree.attr(items[0], kAXChildrenAttribute) ?? []
            }
            let titles = items.map { (AXTree.attr($0, kAXTitleAttribute) as String?) ?? "" }
            let want = menuKey(name)
            guard let index = titles.firstIndex(where: { menuKey($0) == want })
                    ?? titles.firstIndex(where: { !want.isEmpty && menuKey($0).hasPrefix(want) }) else {
                let options = titles.filter { !$0.isEmpty }.prefix(30).joined(separator: ", ")
                return "no menu item \"\(name)\"\(i == 0 ? "" : " under \(path[..<i].joined(separator: " > "))"); there is: \(options)"
            }
            level = items[index]
            if i == path.count - 1 {
                if (AXTree.attr(level, kAXEnabledAttribute) as Bool?) == false { return "\"\(titles[index])\" is greyed out" }
                return AXUIElementPerformAction(level, kAXPressAction as CFString) == .success ? nil : "couldn't choose \"\(titles[index])\""
            }
        }
        return nil
    }

    private static func menuKey(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func actionNames(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    // MARK: Input events

    private static let source = CGEventSource(stateID: .hidSystemState)

    /// `p` is in global AppKit coordinates (origin bottom-left of the primary screen).
    private static func click(at p: CGPoint, double: Bool) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: p.x, y: primaryHeight - p.y)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(60_000)
        for clickCount in 1...(double ? 2 : 1) {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
                e?.post(tap: .cghidEventTap)
                usleep(30_000)
            }
        }
    }

    /// Types by pasting: one atomic insert, so apps can't reorder letters the way they can with fast
    /// synthetic keystrokes, and a newline never acts as Return (which would send a chat message).
    /// The user's clipboard is put back once the paste has landed.
    private static func type(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        press("cmd+v")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    private static func press(_ combo: String) {
        var flags: CGEventFlags = []
        var keyCode: CGKeyCode?
        for part in combo.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            default: keyCode = keyCodes[part]
            }
        }
        guard let keyCode else { return }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }

    private static func open(_ thing: String) {
        if thing.contains("://"), let url = URL(string: thing) {
            NSWorkspace.shared.open(url)
        } else if thing.hasPrefix("www.") || thing.range(of: #"^[\w-]+(\.[\w-]+)+(/\S*)?$"#, options: .regularExpression) != nil,
                  let url = URL(string: "https://" + thing) {
            NSWorkspace.shared.open(url)
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", thing]
            try? p.run()
        }
    }

    private static func scroll(up: Bool) {
        CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: up ? 8 : -8, wheel2: 0, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
    ]
}
