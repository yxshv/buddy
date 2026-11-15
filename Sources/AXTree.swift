import AppKit
import ApplicationServices

/// One control in the front app that Claude can act on by number instead of by pixel.
struct AXControl {
    let element: AXUIElement
    let role: String     // raw AX role, e.g. AXButton
    let kind: String     // short name shown to Claude: button, field, link…
    let label: String?
    let frame: CGRect?   // global AppKit coordinates (origin bottom-left)
    let web: Bool        // inside a web page
    let isSearch: Bool   // a search or address field: Return after typing here only runs the search

    var center: CGPoint? { frame.map { CGPoint(x: $0.midX, y: $0.midY) } }
}

/// The front app's visible controls, read through the Accessibility API (the same permission Buddy
/// already uses to click). Sent to Claude next to each screenshot as a numbered list.
struct AXSnapshot {
    let appName: String
    let windowTitle: String?
    let menus: [String]
    let controls: [Int: AXControl]
    fileprivate let lines: [(id: Int, text: String)]

    /// The list as Claude sees it: centers are mapped into screenshot pixels.
    func listing(in shot: Shot) -> String {
        guard !controls.isEmpty || !menus.isEmpty else { return "" }
        var out = "[Controls in \(appName)\(windowTitle.map { " — window \"\(AXTree.clip($0, 60))\"" } ?? ""):"
        for line in lines {
            var text = "#\(line.id) \(line.text)"
            if let c = controls[line.id]?.center {
                let p = shot.toImage(c)
                if p.x >= 0, p.y >= 0, p.x <= CGFloat(shot.width), p.y <= CGFloat(shot.height) {
                    text += " @\(Int(p.x)),\(Int(p.y))"
                }
            }
            out += "\n" + text
        }
        if !menus.isEmpty { out += "\nMenus: " + menus.joined(separator: ", ") }
        return out + "]"
    }
}

enum AXTree {
    static let maxListed = 160
    private static let maxVisited = 3000
    private static let budget: TimeInterval = 0.7

    private static let kinds: [String: String] = [
        "AXButton": "button", "AXCheckBox": "checkbox", "AXRadioButton": "radio", "AXPopUpButton": "popup",
        "AXMenuButton": "menu button", "AXDisclosureTriangle": "disclosure", "AXLink": "link",
        "AXTextField": "field", "AXTextArea": "text area", "AXComboBox": "combo box", "AXSlider": "slider",
        "AXRow": "row", "AXMenuItem": "menu item", "AXIncrementor": "stepper",
    ]
    private static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    static func editable(_ role: String) -> Bool { editableRoles.contains(role) }
    /// Chromium browsers only build their web accessibility tree once asked to.
    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
    private static var woken = Set<pid_t>()
    private static let wakeLock = NSLock()

    /// The app in front, ignoring Buddy itself.
    static var frontApp: NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        return app
    }

    /// Reads the front window's visible controls. Safe to call off the main thread; gives up after a
    /// short time budget so a huge web page can't stall a turn.
    static func snapshot() -> AXSnapshot? {
        guard AXIsProcessTrusted(), let app = frontApp else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        wake(appEl, app)

        var walker = Walker(deadline: Date().addingTimeInterval(budget))
        let window: AXUIElement? = attr(appEl, kAXFocusedWindowAttribute) ?? attr(appEl, kAXMainWindowAttribute)
            ?? (attr(appEl, kAXWindowsAttribute) as [AXUIElement]?)?.first
        var title: String?
        if let window {
            title = attr(window, kAXTitleAttribute)
            walker.visit(window, clip: frame(of: window) ?? .infinite, web: false, depth: 0)
        }
        // Open pop-up and context menus hang off the app, not the window.
        for child in (attr(appEl, kAXChildrenAttribute) as [AXUIElement]?) ?? [] where (attr(child, kAXRoleAttribute) as String?) == "AXMenu" {
            walker.visit(child, clip: .infinite, web: false, depth: 0)
        }

        let menuBar: AXUIElement? = attr(appEl, kAXMenuBarAttribute)
        let menus = ((menuBar.flatMap { attr($0, kAXChildrenAttribute) } as [AXUIElement]?) ?? [])
            .compactMap { attr($0, kAXTitleAttribute) as String? }
            .filter { !$0.isEmpty && $0 != "Apple" }

        return AXSnapshot(appName: app.localizedName ?? "the app", windowTitle: title?.isEmpty == true ? nil : title,
                          menus: menus, controls: walker.controls, lines: walker.lines)
    }

    /// Wakes the app now in front, so its tree is ready by the time a question comes in.
    static func wakeFront() {
        guard AXIsProcessTrusted(), let app = frontApp else { return }
        wake(AXUIElementCreateApplication(app.processIdentifier), app)
    }

    /// Chrome and Electron apps hide their accessibility tree until an assistive app asks for it,
    /// and take a moment to build it.
    private static func wake(_ appEl: AXUIElement, _ app: NSRunningApplication) {
        wakeLock.lock()
        defer { wakeLock.unlock() }
        guard woken.insert(app.processIdentifier).inserted else { return }
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if chromium.contains(app.bundleIdentifier ?? "") {
            AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    private struct Walker {
        let deadline: Date
        var visited = 0
        var controls: [Int: AXControl] = [:]
        var lines: [(id: Int, text: String)] = []

        private static let wanted = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                                     kAXValueAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute,
                                     kAXChildrenAttribute, kAXPlaceholderValueAttribute, kAXFocusedAttribute] as CFArray

        mutating func visit(_ el: AXUIElement, clip: CGRect, web: Bool, depth: Int) {
            guard depth < 60, visited < AXTree.maxVisited, lines.count < AXTree.maxListed, Date() < deadline else { return }
            visited += 1
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el, Self.wanted, [], &raw) == .success,
                  let values = raw as? [AnyObject], values.count == 11 else { return }
            func value<T>(_ i: Int) -> T? { AXTree.unwrap(values[i]) }

            let role: String = value(0) ?? ""
            let subrole: String? = value(1)
            let frame = AXTree.frame(position: value(5), size: value(6))
            // Scrolled out of view or behind another pane: skip it and everything inside.
            if let frame, frame.width > 0, frame.height > 0, !frame.intersects(clip) { return }
            let inner = role == "AXScrollArea" || role == "AXWebArea" ? (frame.map { $0.intersection(clip) } ?? clip) : clip
            let inWeb = web || role == "AXWebArea"

            if let kind = AXTree.kinds[role], (value(7) as Bool?) != false, frame.map({ $0.width > 1 && $0.height > 1 }) ?? true {
                add(el, role: role, subrole: subrole, kind: kind, frame: frame, web: inWeb,
                    title: value(2), description: value(3), value: values[4], placeholder: value(9),
                    focused: value(10) ?? false)
            }
            for child in (value(8) as [AXUIElement]?) ?? [] {
                visit(child, clip: inner, web: inWeb, depth: depth + 1)
            }
        }

        private mutating func add(_ el: AXUIElement, role: String, subrole: String?, kind: String, frame: CGRect?, web: Bool,
                                  title: String?, description: String?, value raw: AnyObject?, placeholder: String?, focused: Bool) {
            let secure = subrole == "AXSecureTextField"
            let isField = AXTree.editable(role)
            var label = [title, description].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            if label == nil, !isField { label = AXTree.innerText(el) }
            if label == nil { label = placeholder }
            if let l = label, AXTree.clip(l, 50).trimmingCharacters(in: .whitespaces).isEmpty { label = nil }
            // Unlabelled rows and buttons can't be told apart in a list; Claude can still CLICK them.
            if label == nil, !isField { return }

            let isSearch = subrole == "AXSearchField"
                || [label, placeholder].contains { $0?.range(of: "search|address|url|find", options: [.regularExpression, .caseInsensitive]) != nil }
            var text = (secure ? "password field" : isSearch && isField ? "search field" : kind)
            if let label { text += " \"\(AXTree.clip(label, 50))\"" }
            switch role {
            case "AXCheckBox", "AXRadioButton":
                if let on = AXTree.unwrap(raw) as NSNumber? { text += on.intValue == 0 ? " (off)" : " (on)" }
            case _ where isField && !secure:
                if let s = AXTree.unwrap(raw) as String?, !s.isEmpty { text += " = \"\(AXTree.clip(s, 40))\"" }
            case "AXPopUpButton":
                if let s = AXTree.unwrap(raw) as String?, !s.isEmpty, s != label { text += " = \"\(AXTree.clip(s, 30))\"" }
            default: break
            }
            if focused { text += " (focused)" }

            let id = lines.count + 1
            controls[id] = AXControl(element: el, role: role, kind: kind, label: label, frame: frame, web: web, isSearch: isSearch)
            lines.append((id, text))
        }
    }

    /// Text inside an unlabelled row, link or button (its static-text children), so it has a name.
    static func innerText(_ el: AXUIElement, depth: Int = 0) -> String? {
        guard depth < 3 else { return nil }
        var parts: [String] = []
        for child in ((attr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? []).prefix(6) {
            if (attr(child, kAXRoleAttribute) as String?) == "AXStaticText" {
                if let s: String = attr(child, kAXValueAttribute) ?? attr(child, kAXTitleAttribute), !s.isEmpty { parts.append(s) }
            } else if let s = innerText(child, depth: depth + 1) {
                parts.append(s)
            }
            if parts.joined().count > 60 { break }
        }
        let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    // MARK: Helpers

    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value else { return nil }
        return unwrap(value)
    }

    /// AX hands back CF types (and AXValue errors for missing attributes); this casts them, or returns nil.
    static func unwrap<T>(_ v: AnyObject?) -> T? {
        guard let v else { return nil }
        if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
        if T.self == AXUIElement.self { return CFGetTypeID(v) == AXUIElementGetTypeID() ? (v as! T) : nil }
        if T.self == [AXUIElement].self, let arr = v as? [AnyObject] {
            return arr.filter { CFGetTypeID($0) == AXUIElementGetTypeID() }.map { $0 as! AXUIElement } as? T
        }
        if T.self == AXValue.self { return CFGetTypeID(v) == AXValueGetTypeID() ? (v as! T) : nil }
        return v as? T
    }

    static func frame(of el: AXUIElement) -> CGRect? { frame(position: attr(el, kAXPositionAttribute), size: attr(el, kAXSizeAttribute)) }

    /// AX positions are top-left based; Buddy works in AppKit coordinates (bottom-left of the primary screen).
    static func frame(position: AXValue?, size: AXValue?) -> CGRect? {
        var p = CGPoint.zero, s = CGSize.zero
        guard let position, let size, AXValueGetValue(position, .cgPoint, &p), AXValueGetValue(size, .cgSize, &s) else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: p.x, y: primaryHeight - p.y - s.height, width: s.width, height: s.height)
    }

    static func clip(_ s: String, _ n: Int) -> String {
        let flat = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).replacingOccurrences(of: "\"", with: "'")
        return flat.count > n ? flat.prefix(n) + "…" : flat
    }
}
