import AppKit
import Combine
import SwiftUI
import WebKit

// MARK: - Models

/// One exchange in the panel's chat: what you asked, Buddy's answer and any written explanation.
/// Something a task changed, shown as a card under the answer. Clicking opens `url`
/// (a web page in the browser, a file in its app).
struct ResultCard: Equatable, Codable {
    /// note, calendar, file, email, task or link: picks the icon and color.
    var kind = "link"
    var title: String
    var subtitle: String?
    var url: String?

    /// `url` as something NSWorkspace can open: links as they are, paths as files.
    var openURL: URL? {
        guard let url, !url.isEmpty else { return nil }
        if url.hasPrefix("/") || url.hasPrefix("~") { return URL(fileURLWithPath: (url as NSString).expandingTildeInPath) }
        return URL(string: url)
    }
}

struct Turn: Equatable, Encodable {
    var question = ""
    var answer = ""
    var board = ""
    var cards: [ResultCard] = []
    var answered: Bool { !answer.isEmpty || !board.isEmpty || !cards.isEmpty }
    var isEmpty: Bool { question.isEmpty && !answered }
}

/// State of the Siri-style response panel.
final class PanelModel: ObservableObject {
    enum Phase: Equatable { case listening, followUp, thinking, speaking, confirm, notice }

    @Published var visible = false
    @Published var phase: Phase = .notice
    @Published var status = ""
    @Published var turns: [Turn] = []  // the chat, oldest first; it lasts until you press its ✕
    @Published var question = ""       // the confirmation card's question
    @Published var touchID = false     // the card is waiting for a fingerprint (else Do it / Skip buttons)
    @Published var replyHeight: CGFloat = 0
    @Published var maxReplyHeight: CGFloat = 600
    @Published var level: CGFloat = 0 // mic level 0...1
    @Published var hovering = false
    @Published var drawings = false   // something is drawn on screen
    @Published var locked = false     // listening until you press Return

    var onConfirm: (() -> Void)?
    var onDecline: (() -> Void)?
    var onClose: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onOpenChats: (() -> Void)?
    var onClearDrawings: (() -> Void)?

    /// The web view that renders the reply (Markdown and LaTeX); owned by Overlay.
    var replyView: NSView?

    /// Wider once the chat has a written explanation, so equations fit.
    var width: CGFloat { turns.contains { !$0.board.isEmpty } ? Overlay.wideWidth : Overlay.panelWidth }
    var showsReply: Bool { turns.contains { !$0.isEmpty } }
    /// You've actually talked to Buddy in this panel (not just a notice).
    var hasConversation: Bool { turns.contains { !$0.question.isEmpty } }
}

/// The cursor buddy: hidden unless it's pointing at or clicking something.
final class CursorModel: ObservableObject {
    @Published var position = CGPoint.zero // arrow tip, global AppKit coords
    @Published var rotation: Double = 0
    @Published var visible = false
    @Published var label: String?
    @Published var ripple = 0
}

// MARK: - Overlay controller

final class Overlay {
    let panel = PanelModel()
    let cursor = CursorModel()

    static let panelWidth: CGFloat = 380
    static let wideWidth: CGFloat = 560
    static let margin: CGFloat = 32 // transparent room around the panel for its shadow

    private var panelWindow: NSPanel!
    private var panelHost: NSView!
    private let replyWeb = ReplyWeb()
    private var clearWindow: NSPanel!
    private var clearScreen: NSScreen?
    private var panelChanges: AnyCancellable?
    private var panelTop: CGFloat = 0
    private var panelRight: CGFloat = 0
    private var contentHeight: CGFloat = 0
    private var shrinkWork: DispatchWorkItem?
    private var dismissWork: DispatchWorkItem?
    private var dismissDelay: Double?

    private var cursorWindows: [NSWindow] = []
    private var timer: Timer?
    private var flight: Flight?
    private var holdUntil: CFTimeInterval = .infinity
    private var holdFor: Double = 3.5
    private var arrival: (() -> Void)?

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var panelSpring: Animation { reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 1) }
    private var popSpring: Animation { reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.72) }
    private var fadeSpring: Animation { reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 1) }

    private struct Flight {
        var from: CGPoint
        var to: CGPoint
        var control: CGPoint
        var start: CFTimeInterval
        var duration: Double
        var arrived = false
    }

    init() {
        panel.replyView = replyWeb.view
        replyWeb.onHeight = { [weak self] h in
            guard let self, abs(h - self.panel.replyHeight) > 0.5 else { return }
            withAnimation(self.panelSpring) { self.panel.replyHeight = h }
        }
        replyWeb.onOpen = { [weak self] in self?.panel.onOpenChats?() }
        buildPanel()
        buildClearButton()
        buildCursorWindows()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.buildCursorWindows() }
        panel.onHover = { [weak self] inside in
            guard let self else { return }
            if inside { self.dismissWork?.cancel() } else if let d = self.dismissDelay { self.dismiss(after: d) }
        }
    }

    // MARK: Panel API

    /// A new question: added to the open chat, or the start of a new one if the panel was away.
    func listen() {
        if !(panel.visible && panel.hasConversation) { panel.turns = [] }
        startTurn()
        panel.level = 0
        set(.listening, status: "Listening…")
    }

    /// Makes room for the next question (unless an empty one is already waiting).
    func startTurn() {
        if panel.turns.last?.isEmpty != true { panel.turns.append(Turn()) }
        render()
    }

    /// What you're saying, live. After an answer, it starts the next turn of the chat.
    func heard(_ text: String) {
        if panel.turns.last.map({ $0.answered }) ?? true { panel.turns.append(Turn()) }
        panel.turns[panel.turns.count - 1].question = text
        render()
    }

    /// The question that was being heard came to nothing (silence, noise): take it back out.
    /// Without anything left to show, the panel goes away (unless `keepPanel`).
    func dropPending(keepPanel: Bool = false) {
        if let last = panel.turns.last, !last.answered { panel.turns.removeLast() }
        render()
        if panel.showsReply || keepPanel {
            set(.speaking, status: "Buddy") // not listening or transcribing any more
        } else {
            hidePanel()
        }
    }

    /// Nothing more is coming: show `status` over the chat without listening or thinking.
    func settle(_ status: String) { set(.speaking, status: status) }

    /// Listening for a reply after an answer; the answer stays on screen until you speak.
    func followUp() {
        panel.level = 0
        set(.followUp, status: "Listening…")
    }

    /// Locked listening: pauses don't end it, Return sends.
    func setLocked(_ on: Bool) {
        withAnimation(fadeSpring) { panel.locked = on }
    }

    /// Mic level 0...1, smoothed so the orb breathes rather than jitters.
    func level(_ value: Float) { panel.level = max(CGFloat(value), panel.level * 0.82) }

    func think(_ status: String) { set(.thinking, status: status) }

    /// Listening for a spoken yes/no while the confirmation card stays up.
    func listeningForAnswer() {
        withAnimation(panelSpring) { panel.status = "Listening… say yes or no" }
    }

    /// Buddy's answer to the current question, as much as has been spoken so far.
    func say(_ reply: String) {
        if panel.turns.isEmpty { panel.turns.append(Turn()) }
        panel.turns[panel.turns.count - 1].answer = reply
        render()
        if panel.phase != .confirm { set(.speaking, status: "Buddy") }
    }

    /// Written explanation (Markdown and LaTeX) under the reply; replaces the previous one.
    /// Cards for what a task changed, under the current answer.
    func addCards(_ cards: [ResultCard]) {
        guard !cards.isEmpty else { return }
        if panel.turns.isEmpty { panel.turns.append(Turn()) }
        withAnimation(panelSpring) { panel.turns[panel.turns.count - 1].cards += cards }
        render()
        showPanel()
    }

    func board(_ text: String) {
        if panel.turns.isEmpty { panel.turns.append(Turn()) }
        withAnimation(panelSpring) { panel.turns[panel.turns.count - 1].board = text }
        render()
        if panel.phase == .listening || panel.phase == .followUp { set(.speaking, status: "Buddy") } else { showPanel() }
    }

    private func render() {
        replyWeb.setWidth(panel.width - 32)
        replyWeb.show(panel.turns)
    }

    /// Shows or hides the clear-drawings button (in the panel, or on its own when the panel is away).
    func setDrawings(_ on: Bool, screen: CGRect?) {
        if let screen { clearScreen = NSScreen.screens.first { $0.frame == screen } }
        withAnimation(fadeSpring) { panel.drawings = on }
        updateClearButton()
    }

    /// The OK card. With `touchID`, a fingerprint approves it and the card offers only Cancel.
    func ask(_ question: String, touchID: Bool = false) {
        panel.question = question
        panel.touchID = touchID
        set(.confirm, status: "Needs your OK")
    }

    /// A message from Buddy itself. In an open chat it's added like an answer and stays;
    /// on its own it shows briefly.
    func notice(_ text: String, hideAfter: Double = 5) {
        if panel.visible && panel.hasConversation {
            if let last = panel.turns.last, !last.answered {
                panel.turns[panel.turns.count - 1].answer = text
            } else {
                panel.turns.append(Turn(answer: text))
            }
            render()
            set(.notice, status: "Buddy")
        } else {
            panel.turns = [Turn(answer: text)]
            render()
            set(.notice, status: "Buddy")
            dismiss(after: hideAfter)
        }
    }

    /// Hides the panel after `delay` seconds unless the pointer is resting on it.
    func dismiss(after delay: Double) {
        dismissWork?.cancel()
        dismissDelay = delay
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.panel.hovering else { return }
            self.hidePanel()
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// While Buddy clicks or scrolls for you, its panel and buttons let mouse events through, so a
    /// target under the chat still gets the click. Off again puts them back as they were.
    func passThrough(_ on: Bool) {
        if on {
            panelWindow.ignoresMouseEvents = true
            clearWindow.ignoresMouseEvents = true
        } else {
            panelWindow.ignoresMouseEvents = !panel.visible
            updateClearButton()
        }
    }

    func hidePanel() {
        dismissWork?.cancel()
        dismissDelay = nil
        guard panel.visible else { return }
        withAnimation(panelSpring) { panel.visible = false }
        panelWindow.ignoresMouseEvents = true
        updateClearButton()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.panel.visible else { return }
            self.panelWindow.orderOut(nil)
        }
    }

    private func set(_ phase: PanelModel.Phase, status: String) {
        dismissWork?.cancel()
        dismissDelay = nil
        withAnimation(panelSpring) {
            panel.phase = phase
            panel.status = status
        }
        showPanel()
    }

    private func showPanel() {
        guard !panel.visible else { return }
        let frame = NSScreen.underMouse.visibleFrame
        panelTop = frame.maxY - 10 + Self.margin
        panelRight = frame.maxX - 12 + Self.margin
        // Room for the header and what you said; past this the reply scrolls.
        panel.maxReplyHeight = max(frame.height - 10 - Self.margin - 150, 200)
        layoutPanelWindow(CGSize(width: panel.width + Self.margin * 2, height: max(contentHeight, 120)))
        panelWindow.ignoresMouseEvents = false
        panelWindow.orderFrontRegardless()
        withAnimation(panelSpring) { panel.visible = true }
        updateClearButton()
    }

    /// The window hugs the panel so clicks around it reach the apps underneath.
    /// It grows immediately and shrinks only after the content has finished animating.
    private func measurePanel() {
        let size = NSHostingView(rootView: PanelMeasure(model: panel)).fittingSize
        if abs(size.height - contentHeight) > 0.5 || abs(size.width - contentWidth) > 0.5 { contentSized(size) }
    }

    private var contentWidth: CGFloat = 0

    private func contentSized(_ size: CGSize) {
        contentHeight = size.height
        contentWidth = size.width
        shrinkWork?.cancel()
        let current = panelWindow.frame.size
        if size.height >= current.height && size.width >= current.width {
            layoutPanelWindow(size)
        } else {
            // Grow now in whichever direction is growing; shrink once the content has animated in.
            layoutPanelWindow(CGSize(width: max(size.width, current.width), height: max(size.height, current.height)))
            let work = DispatchWorkItem { [weak self] in self?.layoutPanelWindow(size) }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    private func layoutPanelWindow(_ size: CGSize) {
        panelWindow.setFrame(NSRect(x: panelRight - size.width, y: panelTop - size.height, width: size.width, height: size.height), display: true)
    }

    /// A lone "Clear drawings" button at the top right of the screen, for when drawings outlast the panel.
    private func buildClearButton() {
        let size = NSSize(width: 200, height: 76)
        let window = InertPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isFloatingPanel = true
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = FirstMouseHostingView(rootView: FloatingClear(model: panel))
        host.sizingOptions = []
        window.contentView = host
        clearWindow = window
    }

    private func updateClearButton() {
        let show = panel.drawings && !panel.visible
        clearWindow.ignoresMouseEvents = !show
        if show {
            let frame = (clearScreen ?? NSScreen.underMouse).visibleFrame
            let size = clearWindow.frame.size
            clearWindow.setFrameOrigin(NSPoint(x: frame.maxX - 12 + 20 - size.width, y: frame.maxY - 10 + 20 - size.height))
            clearWindow.orderFrontRegardless()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, !(self.panel.drawings && !self.panel.visible) else { return }
                self.clearWindow.orderOut(nil)
            }
        }
    }

    private func buildPanel() {
        let window = InertPanel(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth + Self.margin * 2, height: 200),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isFloatingPanel = true
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = FirstMouseHostingView(rootView: PanelRoot(model: panel))
        host.sizingOptions = []
        window.contentView = host
        panelWindow = window
        panelHost = host
        // Re-measure after every state change (objectWillChange fires before the new values land).
        panelChanges = panel.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.measurePanel() }
        }
    }

    /// Renders the panel (and the buddy, if shown) to PNGs, for checking the design in --demo mode.
    /// Behind-window blur doesn't render this way, so the panel background shows flat.
    func snapshot(_ name: String, into dir: URL) {
        func save(_ view: NSView, _ rect: NSRect, _ file: String) {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return }
            view.cacheDisplay(in: rect, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(file))
        }
        if panel.visible, let v = panelWindow.contentView { save(v, v.bounds, "\(name)-panel.png") }
        if cursor.visible, let w = cursorWindows.first(where: { $0.frame.contains(cursor.position) }), let v = w.contentView {
            let x = cursor.position.x - w.frame.minX
            let yUp = cursor.position.y - w.frame.minY
            let y = v.isFlipped ? v.bounds.height - yUp - 40 : yUp - 120
            save(v, NSRect(x: x - 60, y: y, width: 280, height: 160), "\(name)-cursor.png")
        }
    }

    // MARK: Cursor buddy API

    /// Pops the buddy out of the real cursor, flies it to `target` and shows `label` there.
    /// It vanishes after `hold` seconds (`.infinity`: until `hideBuddy()`).
    func point(at target: CGPoint, label: String?, hold: Double = 3.5, quick: Bool = false, arrived: (() -> Void)? = nil) {
        if !cursor.visible {
            let m = NSEvent.mouseLocation
            cursor.position = CGPoint(x: m.x + 14, y: m.y - 14)
            cursor.rotation = 0
            withAnimation(popSpring) { cursor.visible = true }
        }
        withAnimation(fadeSpring) { cursor.label = nil }

        let from = cursor.position
        let dx = target.x - from.x, dy = target.y - from.y
        let dist = hypot(dx, dy)
        let arc = min(dist * 0.25, 160)
        let mid = CGPoint(x: (from.x + target.x) / 2, y: (from.y + target.y) / 2)
        let control = dist < 1 ? mid : CGPoint(x: mid.x - dy / dist * arc, y: mid.y + dx / dist * arc)
        let duration = dist < 2 ? 0.01
            : reduceMotion ? 0.2
            : quick ? min(max(dist / 3000, 0.2), 0.4) // during tasks: show the move, don't slow it down
            : min(max(dist / 1600, 0.4), 0.9)
        flight = Flight(from: from, to: target, control: control, start: CACurrentMediaTime(), duration: duration)
        holdFor = hold
        holdUntil = .infinity
        arrival = { [weak self] in
            if let label { withAnimation(self?.popSpring) { self?.cursor.label = label } }
            arrived?()
        }
        startTimer()
    }

    /// Flies to `target`, runs `action` (the real click) on arrival with a ripple, then vanishes.
    func click(at target: CGPoint, then action: @escaping () -> Void) {
        point(at: target, label: nil, hold: 0.35, quick: true) { [weak self] in
            action()
            self?.cursor.ripple += 1
        }
    }

    func hideBuddy() {
        flight = nil
        arrival = nil
        withAnimation(fadeSpring) {
            cursor.visible = false
            cursor.label = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            if self?.cursor.visible == false { self?.stopTimer() }
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard var f = flight else { return }
        let now = CACurrentMediaTime()
        let t = min((now - f.start) / f.duration, 1)
        let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        cursor.position = bezier(f.from, f.control, f.to, e)

        // Lean into the direction of travel, straightening out on arrival.
        let tangent = bezierTangent(f.from, f.control, f.to, e)
        if hypot(tangent.x, tangent.y) > 0.001 && !reduceMotion {
            var turn = atan2(-tangent.y, tangent.x) * 180 / .pi + 120 // arrow naturally points up-left
            while turn > 180 { turn -= 360 }
            while turn < -180 { turn += 360 }
            cursor.rotation = turn * sin(.pi * t)
        }

        guard t >= 1 else { return }
        if !f.arrived {
            f.arrived = true
            flight = f
            cursor.rotation = 0
            holdUntil = now + holdFor
            let done = arrival
            arrival = nil
            done?()
        }
        if now >= holdUntil { hideBuddy() }
    }

    private func buildCursorWindows() {
        cursorWindows.forEach { $0.orderOut(nil) }
        cursorWindows = NSScreen.screens.map { screen in
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: CursorView(model: cursor, frame: screen.frame))
            w.orderFrontRegardless()
            return w
        }
    }

    private func bezier(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                       y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }

    private func bezierTangent(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: 2 * (1 - t) * (c.x - a.x) + 2 * t * (b.x - c.x),
                y: 2 * (1 - t) * (c.y - a.y) + 2 * t * (b.y - c.y))
    }
}

// MARK: - Windows

/// The panel's chat (canvas/reply.html). Reports its content height so the panel can size itself,
/// and asks for the chats window when clicked.
private final class ReplyWeb: NSObject, WKScriptMessageHandler {
    let view: PanelWebView
    var onHeight: ((CGFloat) -> Void)?
    var onOpen: (() -> Void)?
    private var ready = false
    private var pending: String?
    private var shown: [Turn]?

    private static let page = Bundle.main.resourceURL?.appendingPathComponent("canvas/reply.html")

    override init() {
        let config = WKWebViewConfiguration()
        view = PanelWebView(frame: NSRect(x: 0, y: 0, width: Overlay.panelWidth - 32, height: 40), configuration: config)
        super.init()
        config.userContentController.add(WeakHandler(self), name: "buddy")
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        if let page = Self.page {
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
    }

    func show(_ turns: [Turn]) {
        guard shown != turns else { return }
        shown = turns
        guard let data = try? JSONEncoder().encode(turns) else { return }
        let js = "chat.set(\(String(decoding: data, as: UTF8.self)))"
        if ready { view.evaluateJavaScript(js) } else { pending = js }
    }

    /// Keeps the page laid out at the panel's text width even while it's off screen, so its height is right.
    func setWidth(_ width: CGFloat) {
        if abs(view.frame.width - width) > 0.5 { view.setFrameSize(NSSize(width: width, height: max(view.frame.height, 40))) }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any], let h = body["height"] as? Double {
            onHeight?(CGFloat(h))
        } else if let body = message.body as? [String: Any], let link = body["open"] as? String {
            if let url = ResultCard(title: "", url: link).openURL { NSWorkspace.shared.open(url) }
        } else if let s = message.body as? String {
            if s == "ready" {
                ready = true
                if let js = pending { view.evaluateJavaScript(js) }
                pending = nil
            } else if s == "open" {
                onOpen?()
            }
        }
    }
}

/// Clicks and scrolls work without making Buddy the active app.
private final class PanelWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A floating panel that never takes focus from the app you're using.
private final class InertPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the panel's buttons work on the first click without activating Buddy.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Behind-window blur, so the panel frosts whatever is underneath it like Siri and Notification Center.
private struct Material: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 22
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - Panel views

private struct PanelRoot: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        PanelView(model: model)
            .padding(Overlay.margin)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

/// The panel at its natural size, used only to measure how tall the window must be.
private struct PanelMeasure: View {
    let model: PanelModel

    var body: some View {
        PanelView(model: model, measuring: true)
            .padding(Overlay.margin)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PanelView: View {
    @ObservedObject var model: PanelModel
    var measuring = false
    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if model.showsReply {
                // Markdown and LaTeX, scrolling once it's taller than the screen allows.
                Group {
                    if measuring { Color.clear } else { ReplyArea(view: model.replyView) }
                }
                .frame(height: min(model.replyHeight, model.maxReplyHeight))
                .transition(.opacity)
            }

            if model.phase == .confirm {
                ConfirmBar(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .padding(16)
        .frame(width: model.width, alignment: .leading)
        .contentShape(shape)
        .onTapGesture { model.onOpenChats?() } // open every chat in a window
        .background(Material())
        .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .clipShape(shape)
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .contentShape(shape)
        .onHover { inside in
            model.hovering = inside
            model.onHover?(inside)
        }
        // Materialize: scale, blur and fade in together, and leave along the same path.
        .scaleEffect(model.visible ? 1 : 0.94, anchor: .top)
        .blur(radius: model.visible ? 0 : 8)
        .opacity(model.visible ? 1 : 0)
        .offset(y: model.visible ? 0 : -8)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Orb(phase: model.phase, level: model.level, running: model.visible)
                .frame(width: 24, height: 24)
            Text(model.status)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
            Spacer(minLength: 8)
            if model.locked && (model.phase == .listening || model.phase == .followUp) {
                LockedHint()
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            if model.drawings {
                ClearDrawingsButton(model: model, compact: true)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            // The only way the chat goes away: it stays put while you work in other apps.
            Button { model.onClose?() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.quaternary))
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .help("Close")
        }
    }
}

/// Shown while listening is locked: pauses won't cut you off, Return sends.
private struct LockedHint: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
            Text("Return to send").font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        .help("Buddy keeps listening through pauses. Press Return to send, Esc to cancel.")
    }
}

/// Hosts the shared reply web view inside the panel.
private struct ReplyArea: NSViewRepresentable {
    let view: NSView?
    func makeNSView(context: Context) -> NSView { view ?? NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Wipes the circles, arrows and notes Buddy drew on screen.
private struct ClearDrawingsButton: View {
    @ObservedObject var model: PanelModel
    let compact: Bool

    var body: some View {
        Button { model.onClearDrawings?() } label: {
            HStack(spacing: 5) {
                Image(systemName: "eraser")
                    .font(.system(size: compact ? 10 : 12, weight: .semibold))
                Text(compact ? "Clear" : "Clear drawings")
                    .font(.system(size: compact ? 11 : 13, weight: .semibold))
            }
            .foregroundStyle(compact ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .padding(.horizontal, compact ? 8 : 13)
            .frame(height: compact ? 22 : 34)
            .background(Capsule().fill(compact ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.regularMaterial)))
            .overlay(compact ? nil : Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(compact ? 0 : 0.22), radius: 10, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .help("Clear drawings")
    }
}

/// The clear-drawings button on its own, top right of the screen, while the panel is away.
private struct FloatingClear: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let shown = model.drawings && !model.visible
        ClearDrawingsButton(model: model, compact: false)
            .scaleEffect(shown ? 1 : 0.9, anchor: .topTrailing)
            .blur(radius: shown ? 0 : 4)
            .opacity(shown ? 1 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 1), value: shown)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

private struct ConfirmBar: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.question)
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if model.touchID {
                    // Approval is your fingerprint on the system prompt; this only declines.
                    Image(systemName: "touchid")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(Color.pink)
                        .symbolEffect(.pulse, options: .repeating)
                    Text("Touch ID to approve")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Pill(title: "Cancel", shortcut: "", primary: false) { model.onDecline?() }
                } else {
                    Spacer()
                    Pill(title: "Skip", shortcut: "", primary: false) { model.onDecline?() }
                    Pill(title: "Do it", shortcut: "", primary: true) { model.onConfirm?() }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.opacity(0.13)))
    }
}

private struct Pill: View {
    let title: String
    let shortcut: String
    let primary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if !shortcut.isEmpty { Text(shortcut).font(.system(size: 11, weight: .medium)).opacity(0.65) }
            }
            .foregroundStyle(primary ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(primary ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
        }
        .buttonStyle(PressStyle())
    }
}

/// Instant feedback on press.
private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 1), value: configuration.isPressed)
    }
}

/// A Siri-like orb: swirls slowly, breathes with your voice while listening, spins faster while thinking.
private struct Orb: View {
    let phase: PanelModel.Phase
    let level: CGFloat
    let running: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || !running)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let listening = phase == .listening || phase == .followUp
            let speed: Double = phase == .thinking ? 2.4 : listening ? 1.2 : 0.5
            let breathe = phase == .thinking ? 0.06 * sin(t * 4) : 0
            let scale = 1 + (listening ? min(level, 1) * 0.35 : 0) + breathe
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: colors, center: .center, angle: .radians(t * speed)))
                    .blur(radius: 2.5)
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.6), .clear], center: UnitPoint(x: 0.35, y: 0.3),
                                         startRadius: 0, endRadius: 11))
            }
            .clipShape(Circle())
            .scaleEffect(scale)
            .shadow(color: colors[1].opacity(0.55), radius: listening ? 3 + level * 8 : 3)
        }
        .animation(.spring(response: 0.4, dampingFraction: 1), value: phase)
    }

    private var colors: [Color] {
        phase == .confirm
            ? [.orange, .yellow, .pink, .orange]
            : [.cyan, .blue, .purple, .pink, .cyan]
    }
}

// MARK: - Cursor views

private struct CursorView: View {
    @ObservedObject var model: CursorModel
    let frame: CGRect
    private let blue = Color(red: 0.16, green: 0.45, blue: 1.0)

    var body: some View {
        let local = CGPoint(x: model.position.x - frame.minX, y: frame.maxY - model.position.y)
        let onThisScreen = local.x > -60 && local.y > -60 && local.x < frame.width + 60 && local.y < frame.height + 60

        ZStack(alignment: .topLeading) {
            Color.clear
            if onThisScreen {
                Ripple(trigger: model.ripple, color: blue)
                    .position(x: local.x, y: local.y)

                BuddyArrow()
                    .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.67, blue: 1), blue], startPoint: .top, endPoint: .bottom))
                    .overlay(BuddyArrow().stroke(Color.white, lineWidth: 1.5))
                    .frame(width: 17, height: 22)
                    .shadow(color: blue.opacity(0.7), radius: 7)
                    .rotationEffect(.degrees(model.rotation), anchor: .topLeading)
                    .scaleEffect(model.visible ? 1 : 0.2, anchor: .topLeading)
                    .opacity(model.visible ? 1 : 0)
                    .offset(x: local.x, y: local.y)

                if let label = model.label {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.regularMaterial))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                        .fixedSize()
                        .offset(x: local.x + 20, y: local.y + 22)
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .topLeading)))
                }
            }
        }
        .frame(width: frame.width, height: frame.height)
    }
}

/// A ring that expands from the arrow tip when Buddy clicks.
private struct Ripple: View {
    let trigger: Int
    let color: Color
    @State private var progress: CGFloat = 1

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 2)
            .frame(width: 40, height: 40)
            .scaleEffect(0.2 + progress * 0.9)
            .opacity(Double(1 - progress))
            .onChange(of: trigger) { _, _ in
                progress = 0
                withAnimation(.easeOut(duration: 0.5)) { progress = 1 }
            }
    }
}

struct BuddyArrow: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: r.width, y: r.height * 0.62))
        p.addLine(to: CGPoint(x: r.width * 0.45, y: r.height * 0.66))
        p.addLine(to: CGPoint(x: r.width * 0.18, y: r.height))
        p.closeSubpath()
        return p
    }
}
