import AppKit
import WebKit

/// The Features & Permissions window, rendered by canvas/settings.html. The page only shows state and
/// reports what was clicked; every change is made here, and the ones that let Buddy do more (a looser
/// level, a new or removed feature) go through `authorize` (Touch ID) first.
final class SettingsWindow: NSObject, WKScriptMessageHandler, NSWindowDelegate {
    /// Asks for Touch ID with a reason ("change what Buddy may do"); runs the closure only on a yes.
    var authorize: ((_ reason: String, _ approved: @escaping () -> Void) -> Void)?
    /// Something changed that Claude's prompt or allow-list depends on.
    var onChange: (() -> Void)?

    private var window: NSWindow?
    private var web: WKWebView?
    private var ready = false
    private var section = "features"

    private static let page = Bundle.main.resourceURL?.appendingPathComponent("canvas/settings.html")

    func show(_ section: String) {
        self.section = section
        if window == nil { build() }
        push(select: true)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Re-reads features and levels from disk, if the window is open.
    func refresh() {
        guard window?.isVisible == true else { return }
        push(select: false)
    }

    // Folders can be edited behind the window's back; coming back to it shows the truth.
    func windowDidBecomeKey(_ notification: Notification) { push(select: false) }

    private func push(select: Bool, flash: String? = nil) {
        guard let web, ready else { return }
        let args = [Self.state(), select ? Self.json(section) : "null", flash.map(Self.json) ?? "null"]
        web.evaluateJavaScript("settings.load(\(args.joined(separator: ", ")))")
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Everything the page shows.
    static func state() -> String {
        func choices(_ levels: [Level]) -> [[String: String]] { levels.map { ["id": $0.rawValue, "title": $0.title] } }
        let features: [[String: Any]] = FeatureStore.all().map { f in
            [
                "id": f.id, "command": f.command, "title": f.manifest.title, "summary": f.manifest.summary,
                "usage": "buddy " + f.usage, "phrases": f.manifest.phrases ?? [], "builtIn": f.builtIn,
                "path": f.dir.path, "problem": f.problem ?? NSNull(), "level": f.level.rawValue,
                "key": f.permissionID, "levels": choices(Feature.levels), "trusted": f.trusted,
            ]
        }
        var groups: [[String: Any]] = []
        for area in Permissions.areas {
            let row: [String: Any] = ["key": area.id, "title": area.title, "detail": area.detail,
                                      "level": Permissions.shared.level(area.id).rawValue, "levels": choices(area.levels)]
            if let i = groups.firstIndex(where: { $0["title"] as? String == area.group }) {
                groups[i]["rows"] = (groups[i]["rows"] as? [[String: Any]] ?? []) + [row]
            } else {
                groups.append(["title": area.group, "rows": [row]])
            }
        }
        let fixed = Permissions.fixed.map { ["title": $0.title, "detail": $0.detail, "level": $0.level] }
        return json(["features": features, "groups": groups, "fixed": fixed, "userDir": FeatureStore.userDir.path,
                     "tampered": Permissions.shared.tampered])
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.body as? String == "ready" {
            ready = true
            push(select: true)
            return
        }
        guard let body = message.body as? [String: Any], let action = body["do"] as? String else { return }
        switch action {
        case "level":
            guard let key = body["key"] as? String, let level = (body["level"] as? String).flatMap(Level.init(rawValue:)) else { return }
            setLevel(key, level)
        case "reveal":
            guard let path = body["path"] as? String else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case "new":
            guard let name = (body["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
            authorize?("add a feature called “\(name)”") { [weak self] in
                switch FeatureStore.scaffold(name) {
                case let .success(dir):
                    self?.changed(flash: "Added. Edit feature.json and run.sh in its folder.")
                    NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent("feature.json")])
                case let .failure(error):
                    self?.push(select: false, flash: error.message)
                }
            }
        case "approve":
            guard let id = body["id"] as? String, let feature = FeatureStore.all().first(where: { $0.id == id }), feature.problem == nil else { return }
            guard let hash = feature.hash else { return }
            authorize?("turn on the feature “\(feature.manifest.title)”") { [weak self] in
                guard FeatureStore.all().first(where: { $0.id == id })?.hash == hash else {
                    self?.push(select: false, flash: "It changed while waiting. Approve it again.")
                    return
                }
                Permissions.shared.approve(id, hash: hash)
                self?.changed(flash: "“\(feature.manifest.title)” is on.")
            }
        case "restore":
            authorize?("restore Buddy's default permissions") { [weak self] in
                Permissions.shared.restoreDefaults()
                self?.changed(flash: "Permissions are back to their defaults. Approve your own features again.")
            }
        case "remove":
            guard let id = body["id"] as? String, let feature = FeatureStore.all().first(where: { $0.id == id }) else { return }
            authorize?("remove the feature “\(feature.manifest.title)”") { [weak self] in
                if let error = FeatureStore.remove(feature) { self?.push(select: false, flash: error.message) }
                else { self?.changed(flash: "Moved “\(feature.manifest.title)” to the Trash.") }
            }
        default: break
        }
    }

    private func setLevel(_ key: String, _ level: Level) {
        let feature = FeatureStore.all().first { $0.permissionID == key }
        guard Permissions.shared.accepts(key, level) else { push(select: false); return }
        let title = feature?.manifest.title ?? Permissions.areas.first { $0.id == key }?.title ?? key
        let apply = { [weak self] in
            Permissions.shared.set(key, level)
            self?.changed(flash: nil)
        }
        // Asking more is always fine. Asking less changes what Buddy may do on its own: fingerprint first.
        guard Permissions.shared.loosens(key, to: level, fallback: feature?.defaultLevel) else { apply(); return }
        guard let authorize else { push(select: false); return }
        authorize("change “\(title)” to “\(level.title)”", apply)
        // Until the fingerprint lands the control shows the old level again.
        push(select: false)
    }

    private func changed(flash: String?) {
        push(select: false, flash: flash)
        onChange?()
    }

    private func build() {
        if NSApp.mainMenu == nil { NSApp.mainMenu = ChatsWindow.menu() }
        let size = NSSize(width: 860, height: 640)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Buddy Settings"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.minSize = NSSize(width: 640, height: 420)
        w.isReleasedWhenClosed = false
        w.delegate = self
        if !w.setFrameUsingName("BuddySettings") { w.center() }
        w.setFrameAutosaveName("BuddySettings")

        let material = NSVisualEffectView()
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        w.contentView = material

        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakHandler(self), name: "buddy")
        let web = WKWebView(frame: material.bounds, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.autoresizingMask = [.width, .height]
        material.addSubview(web)

        let strip = DragStrip(frame: NSRect(x: 0, y: material.bounds.height - 52, width: material.bounds.width, height: 52))
        strip.autoresizingMask = [.width, .minYMargin]
        material.addSubview(strip)

        if let page = Self.page {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        window = w
        self.web = web
    }
}
