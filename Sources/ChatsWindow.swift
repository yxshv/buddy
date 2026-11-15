import AppKit
import WebKit

/// A regular window listing every chat with Buddy, rendered by canvas/chats.html
/// (Markdown and LaTeX like the panel). Opened by clicking the panel or from the menu.
final class ChatsWindow: NSObject, WKScriptMessageHandler, NSWindowDelegate {
    private let log: ChatLog
    private var window: NSWindow?
    private var web: WKWebView?
    private var ready = false
    private var pick: String?

    private static let page = Bundle.main.resourceURL?.appendingPathComponent("canvas/chats.html")

    init(log: ChatLog) {
        self.log = log
        super.init()
        log.onChange = { [weak self] in self?.push() }
    }

    /// Shows the window on the current chat.
    func show() {
        if window == nil { build() }
        pick = log.currentID
        push()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func push() {
        guard let web, ready, window?.isVisible == true || pick != nil else { return }
        let pickArg = pick.map { "\"\($0)\"" } ?? "null"
        pick = nil
        web.evaluateJavaScript("chats.load(\(log.json()), \(pickArg))")
    }

    private func build() {
        if NSApp.mainMenu == nil { NSApp.mainMenu = Self.menu() }
        let size = NSSize(width: 980, height: 680)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Buddy Chats"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.minSize = NSSize(width: 620, height: 400)
        w.isReleasedWhenClosed = false
        w.delegate = self
        if !w.setFrameUsingName("BuddyChats") { w.center() } // first time: centered; then where you left it
        w.setFrameAutosaveName("BuddyChats")

        // Native sidebar material behind the page; the page's sidebar is transparent.
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

        // The page reaches up under the title bar; this strip keeps the window draggable there.
        let strip = DragStrip(frame: NSRect(x: 0, y: material.bounds.height - 52, width: material.bounds.width, height: 52))
        strip.autoresizingMask = [.width, .minYMargin]
        material.addSubview(strip)

        if let page = Self.page {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        window = w
        self.web = web
    }

    /// Buddy has no menu bar of its own; this gives the window ⌘C, ⌘V, ⌘A and ⌘W.
    static func menu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(NSMenuItem(title: "Quit Buddy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        for (title, sub) in [("Buddy", app), ("Edit", edit), ("Window", window)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = sub
            main.addItem(item)
        }
        return main
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.body as? String == "ready" {
            ready = true
            push()
        } else if let body = message.body as? [String: Any], let link = body["open"] as? String,
                  let url = ResultCard(title: "", url: link).openURL {
            NSWorkspace.shared.open(url) // a result card was clicked
        }
    }
}

/// Drags the window (double-click zooms) where the web page sits under the transparent title bar.
final class DragStrip: NSView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}
