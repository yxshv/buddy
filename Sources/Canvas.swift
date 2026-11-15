import AppKit
import WebKit

/// A transparent, click-through layer over the screen that Buddy draws on: circles, arrows, boxes,
/// highlights and note cards with LaTeX (canvas/canvas.html, rendered by WebKit).
/// One window per screen, created the first time Buddy draws there.
final class Canvas: NSObject, WKScriptMessageHandler {
    private final class Layer {
        let frame: CGRect
        let window: NSWindow
        let web: WKWebView
        var ready = false
        var drawn = false
        var pending: [String] = []
        init(frame: CGRect, window: NSWindow, web: WKWebView) { self.frame = frame; self.window = window; self.web = web }
    }

    private var layers: [Layer] = []

    /// Whether anything is drawn, and on which screen (its frame), whenever that changes.
    var onChange: ((Bool, CGRect?) -> Void)?

    private static let page = Bundle.main.resourceURL?.appendingPathComponent("canvas/canvas.html")

    /// Draws marks given in `shot`'s pixels on the screen it was taken of.
    func draw(_ marks: [Mark], shot: Shot?) {
        guard !marks.isEmpty else { return }
        let frame = shot?.frame ?? NSScreen.underMouse.frame
        // Screenshot pixels → points from the screen's top-left corner, which is what the page uses.
        let sx = shot.map { frame.width / CGFloat($0.width) } ?? 1
        let sy = shot.map { frame.height / CGFloat($0.height) } ?? 1
        let pt = { (p: CGPoint) -> [Double] in [Double(p.x * sx), Double(p.y * sy)] }
        let rect = { (r: CGRect) -> [Double] in [Double(r.minX * sx), Double(r.minY * sy), Double(r.width * sx), Double(r.height * sy)] }

        for mark in marks {
            var cmd: [String: Any]
            switch mark {
            case let .arrow(from, to, label, color): cmd = ["kind": "arrow", "from": pt(from), "to": pt(to), "label": label ?? "", "color": color ?? ""]
            case let .circle(r, label, color): cmd = ["kind": "circle", "rect": rect(r), "label": label ?? "", "color": color ?? ""]
            case let .box(r, label, color): cmd = ["kind": "box", "rect": rect(r), "label": label ?? "", "color": color ?? ""]
            case let .underline(from, to, color): cmd = ["kind": "underline", "from": pt(from), "to": pt(to), "color": color ?? ""]
            case let .highlight(r, color): cmd = ["kind": "highlight", "rect": rect(r), "color": color ?? ""]
            case let .note(at, text, color): cmd = ["kind": "note", "text": text, "color": color ?? ""]; if let at { cmd["at"] = pt(at) }
            case .board: continue // boards go in the chat panel
            case .clear: clear(); continue
            }
            run("buddy.draw(\(json(cmd)))", on: layer(for: frame))
        }
    }

    /// Wipes the canvas on every screen.
    func clear() {
        for layer in layers where layer.window.isVisible || !layer.pending.isEmpty {
            run("buddy.clear()", on: layer, show: false)
        }
    }

    private func run(_ js: String, on layer: Layer, show: Bool = true) {
        if show { layer.window.orderFrontRegardless() }
        if layer.ready {
            layer.web.evaluateJavaScript(js)
        } else {
            layer.pending.append(js)
        }
    }

    private func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func layer(for frame: CGRect) -> Layer {
        if let existing = layers.first(where: { $0.frame == frame }) { return existing }

        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakHandler(self), name: "buddy")
        let web = WKWebView(frame: CGRect(origin: .zero, size: frame.size), configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.autoresizingMask = [.width, .height]

        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true // clicks go straight through to the apps underneath
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1) // under Buddy's panel and cursor
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.contentView = web

        let layer = Layer(frame: frame, window: window, web: web)
        layers.append(layer)
        if let page = Self.page {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return layer
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let layer = layers.first(where: { $0.web === message.webView }), let state = message.body as? String else { return }
        switch state {
        case "ready":
            layer.ready = true
            let pending = layer.pending
            layer.pending.removeAll()
            pending.forEach { layer.web.evaluateJavaScript($0) }
        case "empty", "busy":
            if state == "empty" { layer.window.orderOut(nil) } // nothing drawn: take the window off screen
            let was = layers.contains { $0.drawn }
            layer.drawn = state == "busy"
            let now = layers.first { $0.drawn }
            if was != (now != nil) || state == "busy" { onChange?(now != nil, now?.frame) }
        default:
            break
        }
    }

    /// `--canvas-test <dir>`: draws a sample on the screen under the mouse, saves canvas.png into <dir>, quits.
    func selfTest(into dir: URL) {
        let f = NSScreen.underMouse.frame
        let w = Double(f.width), h = Double(f.height)
        draw([
            .circle(CGRect(x: w * 0.18, y: h * 0.30, width: 180, height: 28), label: "This one", color: nil),
            .arrow(from: CGPoint(x: w * 0.42, y: h * 0.62), to: CGPoint(x: w * 0.28, y: h * 0.40), label: "Look here", color: "orange"),
            .box(CGRect(x: w * 0.12, y: h * 0.70, width: 140, height: 36), label: "Save", color: "green"),
            .note(at: CGPoint(x: w * 0.45, y: h * 0.70), text: "Units: $\\lambda$ in **nm**.", color: "blue"),
        ], shot: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in
            guard let layer = layers.first else { NSApp.terminate(nil); return }
            layer.web.takeSnapshot(with: nil) { image, _ in
                if let image {
                    // Composite on gray so the transparent parts are visible in the PNG.
                    let out = NSImage(size: image.size)
                    out.lockFocus()
                    NSColor(white: 0.55, alpha: 1).setFill()
                    NSRect(origin: .zero, size: image.size).fill()
                    image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
                    out.unlockFocus()
                    if let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: dir.appendingPathComponent("canvas.png"))
                    }
                }
                NSApp.terminate(nil)
            }
        }
    }
}

/// WKUserContentController retains its handlers; this keeps it from retaining its owner.
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
