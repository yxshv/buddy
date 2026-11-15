import AppKit
import Carbon
import LocalAuthentication

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var overlay: Overlay!
    private var lockKey: Hotkey!   // ⌃⌥L: listen until Return
    private var sendKey: Hotkey!   // Return, only while listening is locked
    private var escKey: Hotkey!    // Esc, only while listening is locked
    private var parser: ReplyParser!
    private let listener = Listener()
    private let voice = Voice()
    private let claude = ClaudeBridge()
    private let canvas = Canvas()
    private let chatLog = ChatLog()
    private lazy var chatsWindow = ChatsWindow(log: chatLog)
    private lazy var settingsWindow = SettingsWindow()
    private let defaults = UserDefaults.standard

    private var talking = false
    private var followingUp = false   // listening for a reply without "Hey Buddy" after an answer
    private var captureIsFollowUp = false // the current capture started as a follow-up (stays set once you speak)
    private var conversationOver = false  // Claude ended with [END]: don't listen for a follow-up
    private var wakeEnabled = true
    private var turn = 0
    private var shot: Shot?
    private var controls: AXSnapshot? // the numbered controls sent with this turn's screenshot
    private var reply = ""
    private var board = "" // the written explanation for this request, shown in the panel
    private var cards: [ResultCard] = [] // what this request changed, shown as cards and kept in the chat log

    // Computer control: harmless steps run straight away; risky ones wait here for a yes.
    private var queued: [Step] = []
    private var autoSafe = true
    private var awaiting = false   // a confirmation question is showing
    private var answering = false  // the user is replying to it by voice
    private var didActions: [String] = []
    private var steps = 0
    private let maxSteps = 15
    // While Buddy works through a task it stays quiet: words are held back and only spoken
    // if the turn ends without another action (a question for you, or "done").
    private var taskTurn = false
    private var sawAction = false
    private var heldText: [(text: String, targets: [(CGPoint, String?)], marks: [Mark])] = []
    private var streamingSpeech = false // this reply turned out to be an answer: speak as it arrives
    private var listenAfterSpeech = false
    private var announcedTask = false // said "On it" for this request
    private var stepInFlight = false  // a step is running or settling; nothing else may start
    private var permission: ToolPermission? // Claude Code is waiting for your OK on one of its tools
    private var pendingCommand: (approve: () -> Void, reply: (String) -> Void, area: String?)? // a `buddy` CLI step waiting for your OK
    private var authContext: LAContext? // the Touch ID prompt for the step on the OK card
    private var commandServer: CommandServer?
    /// Areas you've said yes to in this request: more of the same kind doesn't ask again (except destructive
    /// steps). A yes to a settings change or a feature run carries over to nothing.
    private var approvedAreas: Set<String> = []

    private let models = [("Sonnet (balanced)", "sonnet"), ("Haiku (fastest)", "haiku"), ("Opus (smartest)", "opus")]

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        overlay = Overlay()
        claude.model = defaults.string(forKey: "model") ?? "sonnet"
        voice.enabled = defaults.object(forKey: "speak") as? Bool ?? true
        autoSafe = defaults.object(forKey: "autoSafe") as? Bool ?? true
        voice.voiceID = defaults.string(forKey: "voice") ?? "af_heart"
        wakeEnabled = defaults.object(forKey: "wake") as? Bool ?? true

        parser = ReplyParser { [weak self] chunk in self?.sentence(chunk) }
        // Browsers and Electron apps build their accessibility tree only once asked, which takes a moment:
        // ask as soon as an app comes to the front, so the control list is ready for the next question.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            DispatchQueue.global(qos: .utility).async { AXTree.wakeFront() }
        }
        DispatchQueue.global(qos: .utility).async { AXTree.wakeFront() }
        listener.onWake = { [weak self] in self?.beginTalking() }
        listener.onPartial = { [weak self] text in
            guard let self, self.talking, !text.isEmpty else { return }
            self.followingUp = false
            // Yes/no answers to a confirmation aren't chat questions.
            if !self.answering { self.overlay.heard(text) } // after an answer, this starts the next turn
        }
        listener.onLevel = { [weak self] level in if self?.talking == true { self?.overlay.level(level) } }
        listener.onCommand = { [weak self] audio, text in self?.endTalking(audio: audio, appleText: text) }
        listener.onSilence = { [weak self] in self?.heardNothing() }
        overlay.panel.onConfirm = { [weak self] in if self?.awaiting == true { self?.runNext() } }
        overlay.panel.onDecline = { [weak self] in if self?.awaiting == true { self?.decline() } }
        overlay.panel.onClose = { [weak self] in self?.closePanel() }
        overlay.panel.onOpenChats = { [weak self] in self?.chatsWindow.show() }
        overlay.panel.onClearDrawings = { [weak self] in self?.canvas.clear() }
        canvas.onChange = { [weak self] drawn, screen in self?.overlay.setDrawings(drawn, screen: screen) }
        claude.onText = { [weak self] text in self?.parser.feed(text) }
        claude.onStatus = { [weak self] status in self?.overlay.think(status) }
        claude.onTurnEnd = { [weak self] error in self?.turnEnded(error) }
        claude.onToolUse = { [weak self] name in self?.toolUsed(name) }
        claude.onPermission = { [weak self] request in self?.permissionRequested(request) }
        voice.onIdle = { [weak self] in self?.settleIfDone() }

        // Only registered while a confirmation is showing.
        lockKey = Hotkey(keyCode: UInt32(kVK_ANSI_L))
        lockKey.onPress = { [weak self] in self?.toggleLockedListening() }
        sendKey = Hotkey(keyCode: UInt32(kVK_Return), modifiers: 0, enabled: false)
        sendKey.onPress = { [weak self] in self?.sendLocked() }
        escKey = Hotkey(keyCode: UInt32(kVK_Escape), modifiers: 0, enabled: false)
        escKey.onPress = { [weak self] in self?.closePanel() }

        buildMenu()
        Permissions.shared.onChange = { [weak self] in self?.commandSettingsChanged() }

        // The `buddy` CLI that Claude (or you) can run to see and control the screen.
        commandServer = CommandServer { [weak self] args, stdin, reply in
            guard let self else { reply("error: Buddy is shutting down"); return }
            BuddyCommands.run(args, stdin: stdin, host: self, reply: reply)
        }
        commandServer?.start()

        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if Whisper.available { Whisper.warmUp() }

        // `--settle-test <file>`: time the screen-settle wait on the current screen, write it to <file>, quit.
        if let i = CommandLine.arguments.firstIndex(of: "--settle-test"), i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            let t0 = CACurrentMediaTime()
            ScreenSettle.wait(min: 0.55, max: 5) {
                let first = CACurrentMediaTime() - t0
                let t1 = CACurrentMediaTime()
                ScreenSettle.wait(min: 0.3, max: 2.5) {
                    let text = String(format: "WAIT on a still screen: %.2fs\nafter-click check: %.2fs\n", first, CACurrentMediaTime() - t1)
                    try? text.write(toFile: out, atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                }
            }
            return
        }

        // `--canvas-test <dir>`: draw a sample on screen, save a snapshot into <dir>, quit.
        if let i = CommandLine.arguments.firstIndex(of: "--canvas-test"), i + 1 < CommandLine.arguments.count {
            canvas.selfTest(into: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            return
        }

        if CommandLine.arguments.contains("--demo") {
            runDemo()
            return
        }
        // `--scene <file.json>`: stage one exchange for screenshots (see runScene).
        if let i = CommandLine.arguments.firstIndex(of: "--scene"), i + 1 < CommandLine.arguments.count {
            runScene(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            return
        }

        Listener.requestPermissions { [weak self] ok in
            guard let self else { return }
            if !ok {
                self.overlay.notice("Buddy needs Microphone and Speech Recognition access (System Settings › Privacy & Security), then a relaunch.", hideAfter: 10)
            } else if self.wakeEnabled {
                self.startListening()
            }
        }

        if claude.claudePath == nil {
            overlay.notice("Couldn't find the claude CLI. Install Claude Code and log in, then relaunch Buddy.", hideAfter: 12)
        } else {
            claude.warmUp()
            overlay.notice(wakeEnabled ? "Say “Hey Buddy” and ask me anything." : "Choose Ask Buddy in the menu bar to talk to me.", hideAfter: 5)
        }
    }

    // MARK: Conversation flow

    private func startListening() {
        do {
            try listener.start()
        } catch {
            overlay.notice("Can't listen: \(error.localizedDescription)", hideAfter: 8)
        }
    }

    /// "Hey Buddy" was heard (or a follow-up answer is expected).
    private func beginTalking() {
        guard !talking else { return }
        if awaiting { decline() } // only your fingerprint approves; talking again means "not that"
        talking = true
        turn += 1
        answering = false
        voice.stop()
        NSSound(named: "Pop")?.play()
        canvas.clear() // circles and arrows were about the last question
        followingUp = false
        captureIsFollowUp = false
        stepInFlight = false
        queued.removeAll()
        didActions.removeAll()
        claude.cancel()
        permission = nil
        cancelCommand()
        parser.reset()
        reply = ""
        overlay.hideBuddy()
        overlay.listen()
    }

    // MARK: Locked listening

    /// ⌃⌥L: keep listening through pauses until Return. Pressing it mid-sentence locks the current capture;
    /// pressing it again sends, like Return.
    private func toggleLockedListening() {
        if listener.held { sendLocked(); return }
        if !(talking && listener.capturing) {
            if !listener.running { startListening() }
            guard listener.running else { return }
            if !talking { beginTalking() }
            followingUp = false
            listener.listenNow()
        }
        guard listener.capturing else { return }
        captureIsFollowUp = false // you asked to be heard: don't treat it as possible background noise
        listener.held = true
        setLocked(true)
    }

    private func sendLocked() {
        guard listener.held else { return }
        setLocked(false)
        listener.finishNow()
    }

    /// Return and Esc are only taken from other apps while listening is locked.
    private func setLocked(_ on: Bool) {
        if !on { listener.held = false }
        sendKey.setEnabled(on)
        escKey.setEnabled(on)
        overlay.setLocked(on)
    }

    /// Nothing was said after waking up.
    private func heardNothing() {
        setLocked(false)
        guard talking else { return }
        talking = false
        followingUp = false
        captureIsFollowUp = false
        if answering {
            answering = false // still waiting; the buttons and ⌃⌥Y / ⌃⌥N keep working
            reask()
        } else {
            // The chat stays until you press its ✕; an empty panel just goes.
            overlay.dropPending()
        }
        stopIfNotListening()
    }

    private func endTalking(audio: [Float], appleText: String) {
        setLocked(false)
        guard talking else { return }
        talking = false
        let wasFollowUp = captureIsFollowUp
        captureIsFollowUp = false
        voice.prepare() // load the voice model while Claude thinks
        let thisTurn = turn
        let (capture, mouse) = captureScreen() // grab the screen while Whisper transcribes
        if !answering { overlay.think("Transcribing…") }

        Whisper.transcribe(audio) { [weak self] text in
            guard let self, thisTurn == self.turn else { return }
            self.stopIfNotListening()
            let said = Listener.stripWakePhrase(text ?? appleText)

            if !self.answering {
                // Whisper can invent words ("Thank you.") from background noise. In a follow-up, only
                // accept speech the on-device recognizer also heard as words.
                if wasFollowUp && appleText.trimmingCharacters(in: .whitespaces).isEmpty {
                    capture.cancel()
                    self.overlay.dropPending()
                    return
                }
                if Self.isGoodbye(said) {
                    capture.cancel()
                    self.endConversation(said)
                    return
                }
            }

            if self.answering {
                self.answering = false
                switch Self.intent(said) {
                case .yes: capture.cancel(); self.runNext(); return
                case .no: capture.cancel(); self.decline(); return
                case .unclear where said.isEmpty: // still waiting for an answer
                    capture.cancel()
                    self.reask()
                    return
                case .unclear: // a new request instead
                    self.overlay.startTurn()
                    self.setAwaiting(false)
                    self.queued.removeAll()
                    self.didActions.removeAll()
                    self.claude.cancel()
                    self.permission = nil
                    self.cancelCommand()
                    self.parser.reset()
                    self.reply = ""
                    self.overlay.hideBuddy()
                }
            }
            guard !said.isEmpty else {
                capture.cancel()
                if wasFollowUp || self.overlay.panel.hasConversation {
                    self.overlay.dropPending(keepPanel: !wasFollowUp)
                    if !wasFollowUp { self.overlay.notice("Didn't catch that.", hideAfter: 2) }
                } else {
                    self.overlay.notice("Didn't catch that.", hideAfter: 2)
                }
                return
            }
            self.steps = 0
            self.followingUp = false
            self.taskTurn = false
            self.sawAction = false
            self.announcedTask = false
            self.approvedAreas = []
            self.conversationOver = false
            self.streamingSpeech = false
            self.heldText = []
            self.board = ""
            self.cards = []
            self.chatLog.add("user", text: said)
            self.overlay.heard(said)
            self.overlay.think("Thinking…")
            self.send(capture: capture, mouse: mouse, turn: thisTurn) { shot, m in
                """
                [Screenshot attached: \(shot.width)x\(shot.height) px. Mouse at (\(Int(m.x)), \(Int(m.y))).]
                User said: "\(said)"
                """
            }
        }
    }

    /// With "Hey Buddy" turned off, the mic only runs for a single question from the menu.
    private func stopIfNotListening() {
        if !wakeEnabled && !awaiting && !talking { listener.stop() }
    }

    private func captureScreen() -> (Task<Shot, Error>, CGPoint) {
        let screen = NSScreen.underMouse
        let frame = screen.frame, displayID = screen.displayID
        return (Task { try await ScreenGrabber.capture(frame: frame, displayID: displayID) }, NSEvent.mouseLocation)
    }

    private func send(capture: Task<Shot, Error>, mouse: CGPoint, turn thisTurn: Int, message: @escaping (Shot, CGPoint) -> String) {
        // "Look at the screen" is off: no screenshot and no controls list, just what was said.
        if Permissions.shared.level("screen.look") == .off {
            capture.cancel()
            shot = nil
            controls = nil
            let text = message(Shot.blank, .zero)
                .replacingOccurrences(of: #"\[Screenshot attached[^\]]*\]\s*|Updated screenshot attached[^.]*\.\s*|Mouse at \(0, 0\)\.?\s*"#, with: "", options: .regularExpression)
            claude.send(text: "[The user turned off screen access in Buddy's settings: no screenshot.]\n" + text, jpeg: nil)
            return
        }
        // Read the front app's controls while the screenshot is taken.
        let tree = Task.detached { AXTree.snapshot() }
        Task { @MainActor in
            do {
                let shot = try await capture.value
                let controls = await tree.value
                guard thisTurn == self.turn else { return }
                self.shot = shot
                self.controls = controls
                let listing = controls?.listing(in: shot) ?? ""
                self.claude.send(text: message(shot, shot.toImage(mouse)) + (listing.isEmpty ? "" : "\n" + listing), jpeg: shot.jpeg)
            } catch {
                self.overlay.notice("Screen capture failed. Allow Buddy in System Settings › Privacy & Security › Screen Recording, then relaunch.", hideAfter: 10)
            }
        }
    }

    // MARK: Claude Code's own tools

    /// Words said before a tool call were narration ("Let me find that project"): drop them, and once
    /// Buddy is really doing something (not just looking), stay quiet until it's done.
    private func toolUsed(_ name: String) {
        if !streamingSpeech {
            heldText.removeAll()
            reply = ""
        }
        streamingSpeech = false
        let looking = name == "ToolSearch" || ["Read", "Glob", "Grep", "WebSearch", "WebFetch", "TodoWrite"].contains(name)
            || ToolPermission.readOnly.contains(name)
        guard !looking else { return }
        sawAction = true
        if !announcedTask {
            announcedTask = true
            voice.say("On it.") {}
        }
    }

    /// Claude Code wants to run a command, edit a file, change a note…: ask, unless you've already
    /// said yes in this task and it isn't destructive.
    private func permissionRequested(_ request: ToolPermission) {
        // The user's competitive-programming code is never changed, whatever anyone approves.
        if request.touchesProtectedCode {
            claude.answer(request, allow: false, because: "The user never lets Buddy change their competitive-programming code (\(Permissions.protectedFolders.joined(separator: ", "))), not even when asked to fix it. Reading and compiling it elsewhere is fine.")
            return
        }
        // The request's row on the Permissions screen decides; destructive things ask whatever it says.
        let level = request.area.map { Permissions.shared.level($0) } ?? .risky
        if level == .off {
            claude.answer(request, allow: false, because: "The user turned this off in Buddy's settings.")
            return
        }
        let trusted = level == .allow || (level == .risky && autoSafe && request.area.map(approvedAreas.contains) == true)
        if trusted && !request.isDestructive {
            claude.answer(request, allow: true)
            return
        }
        permission = request
        askApproval(request.prompt, spoken: request.spoken)
    }

    private func answerPermission(_ allow: Bool) {
        guard let request = permission else { return }
        permission = nil
        stopAnswerCapture()
        setAwaiting(false)
        if allow, let area = request.area { approvedAreas.insert(area) } // more of the same in this request won't ask (except destructive)
        claude.answer(request, allow: allow)
        overlay.think(allow ? "Working on it…" : "Okay, skipping that…")
    }

    /// Puts the pending question back on the card.
    private func reask() {
        if let permission { overlay.ask(permission.prompt) }
        else if let step = queued.first { overlay.ask(step.action.prompt) }
    }

    private func sentence(_ chunk: ReplyParser.Chunk) {
        let thisTurn = turn
        let text = chunk.text, actions = chunk.actions
        let toScreen: (CGPoint) -> CGPoint = { [shot] p in shot?.toScreen(p) ?? p }
        var afterSearchField = false
        queued += actions.map { step in
            var step = step.mapped(toScreen).resolved(controls)
            // Return right after typing into a listed search or address field only runs the search.
            if case let .key(combo) = step.action, afterSearchField, ["return", "enter"].contains(combo.lowercased()) { step.markedSafe = true }
            if case let .set(_, _, control) = step.action { afterSearchField = control?.isSearch == true }
            else if case .key = step.action {} else { afterSearchField = false }
            return step
        }
        if chunk.ends { conversationOver = true }
        // "Draw and point" is off: drop the marks and the pointing, keep the words.
        let drawing = Permissions.shared.level("screen.draw") != .off
        if !actions.isEmpty {
            sawAction = true
            // Let you know once that Buddy is working on it; individual steps stay silent.
            if !announcedTask {
                announcedTask = true
                voice.say("On it.") {}
                overlay.think("Working on it…")
            }
        }
        let targets = drawing ? chunk.points.map { (toScreen(CGPoint(x: $0.x, y: $0.y)), $0.label) } : []
        // Boards are written into the chat panel, which scrolls; everything else is drawn on screen.
        var marks: [Mark] = []
        for mark in chunk.marks {
            if case let .board(_, _, text) = mark {
                board = text
                overlay.board(text)
            } else if drawing {
                marks.append(mark)
            }
        }
        if !text.isEmpty { reply += (reply.isEmpty ? "" : " ") + text }

        // Drawings go with the sentence that talks about them; with nothing to say, draw right away.
        if text.isEmpty || taskTurn || sawAction {
            canvas.draw(marks, shot: shot)
            marks = []
        }
        // Working on a task: don't narrate each step. Hold the words; turnEnded speaks them only
        // if this turn ends without another action.
        if taskTurn || sawAction {
            if !text.isEmpty { heldText.append((text, [], [])) }
            for target in targets { overlay.point(at: target.0, label: target.1) }
            return
        }
        if streamingSpeech {
            speak(text, targets: targets, marks: marks, turn: thisTurn)
            return
        }
        // Hold the first sentence: if an action follows it was narration ("I'll open YouTube") and is
        // dropped. A second sentence means this is a real answer, so start speaking.
        heldText.append((text, targets, marks))
        if heldText.count >= 2 {
            streamingSpeech = true
            let held = heldText
            heldText = []
            for item in held { speak(item.text, targets: item.targets, marks: item.marks, turn: thisTurn) }
        }
    }

    private func speak(_ text: String, targets: [(CGPoint, String?)], marks: [Mark], turn thisTurn: Int) {
        let shown = reply
        let shot = shot
        voice.say(text) { [weak self] in
            guard let self, thisTurn == self.turn else { return }
            self.canvas.draw(marks, shot: shot)
            for (i, target) in targets.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.4) {
                    guard thisTurn == self.turn else { return }
                    self.overlay.point(at: target.0, label: target.1)
                }
            }
            if !shown.isEmpty { self.overlay.say(shown) }
        }
    }

    private func turnEnded(_ error: String?) {
        parser.finish()
        if let error {
            queued.removeAll()
            overlay.notice(error, hideAfter: 10)
        } else if reply.localizedCaseInsensitiveContains("authenticate") || reply.localizedCaseInsensitiveContains("/login") {
            overlay.notice(reply + " Open Terminal, run `claude`, and type /login.", hideAfter: 15)
        } else if queued.isEmpty && !heldText.isEmpty {
            // A short answer, or the task is finished, or Claude needs you: now it's worth saying out loud.
            let held = heldText
            reply = held.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
            for item in held { speak(item.text, targets: item.targets, marks: item.marks, turn: turn) }
        }
        if error == nil && queued.isEmpty { chatLog.add("buddy", text: reply, board: board, cards: cards) }
        heldText = []
        streamingSpeech = false
        settleIfDone()
    }

    private func settleIfDone() {
        // While Claude waits for your OK on a tool it's still busy, but the question still needs an answer.
        guard !talking, !claude.busy || permission != nil || pendingCommand != nil, !stepInFlight else { return }
        if voice.isSpeaking {
            // Harmless steps don't wait for "On it" to finish; questions and follow-ups do.
            if !awaiting, let step = queued.first, autoSafe && step.runsWithoutAsking { nextStep() }
            return
        }
        if awaiting {
            // The question has been spoken; now listen for the answer.
            if listenAfterSpeech {
                listenAfterSpeech = false
                listenForAnswer()
            }
            return
        }
        if !queued.isEmpty {
            nextStep()
        } else {
            startFollowUp()
        }
    }

    /// "That's all", "I'll continue later", "thanks, bye": wrap up without asking Claude or listening again.
    private static func isGoodbye(_ said: String) -> Bool {
        let s = said.lowercased().replacingOccurrences(of: #"[^a-z' ]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if s.range(of: #"\b(continue|carry on|do|pick|talk|finish|resume)( (this|it|that))?( up| to you)? later\b"#, options: .regularExpression) != nil {
            return true
        }
        let closing = #"^(ok(ay)? |alright |cool |great )?(thanks?( you)?( so much)?|that'?s (all|it|enough)|that is all|nothing( else)?|no thanks?( you)?|never ?mind|bye( bye)?|good ?bye|see (you|ya)( later)?|later|stop( listening)?|i'?m (done|good)|we'?re done|done|good night|leave it)( for (now|today))?( buddy| bye)?$"#
        return s.range(of: closing, options: .regularExpression) != nil
    }

    private func endConversation(_ said: String) {
        followingUp = false
        conversationOver = false
        reply = ""
        voice.say("Okay, talk later.") {}
        let chatting = overlay.panel.hasConversation
        overlay.heard(said)
        overlay.say("Okay, talk later.")
        overlay.settle("Buddy")
        // Just "bye" on its own: nothing to keep reading, so let it go. A chat stays until you press its ✕.
        if !chatting { overlay.dismiss(after: 2.5) }
        stopIfNotListening()
    }

    /// After an answer, keep listening briefly so you can reply without saying "Hey Buddy" again.
    private func startFollowUp() {
        if conversationOver {
            conversationOver = false
            overlay.settle("Buddy") // done listening; the chat stays until you press its ✕
            return
        }
        guard !reply.isEmpty else { overlay.settle("Buddy"); return }
        if !listener.running { startListening() }
        guard listener.running else {
            overlay.settle("Buddy")
            return
        }
        talking = true
        answering = false
        followingUp = true
        captureIsFollowUp = true
        turn += 1
        queued.removeAll()
        didActions.removeAll()
        parser.reset()
        reply = ""
        overlay.followUp()
        listener.listenNow(afterSpeech: true)
    }

    /// Listen for a spoken yes/no to the question on the confirmation card.
    private func listenForAnswer() {
        guard awaiting, !talking else { return }
        if !listener.running { startListening() }
        guard listener.running else { return }
        talking = true
        answering = true
        turn += 1
        overlay.listeningForAnswer()
        listener.listenNow(afterSpeech: true)
    }

    // MARK: Computer control

    private enum Intent { case yes, no, unclear }

    private static func intent(_ said: String) -> Intent {
        let s = said.lowercased().replacingOccurrences(of: #"[^a-z' ]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if s.range(of: #"^(yes|yeah|yep|yup|sure|ok|okay|do it|go ahead|go for it|confirm|please do|yes please)\b"#, options: .regularExpression) != nil { return .yes }
        if s.range(of: #"^(no|nope|nah|stop|cancel|don't|do not|never ?mind|skip)\b"#, options: .regularExpression) != nil { return .no }
        return .unclear
    }

    private func setAwaiting(_ on: Bool) {
        awaiting = on
        if !on {
            authContext?.invalidate() // a Touch ID prompt still up for this step goes away
            authContext = nil
        }
    }

    /// Asks for your OK: the question on the card and out loud, and a Touch ID prompt. Your fingerprint
    /// approves it; cancelling (or Cancel on the card) declines. Voice and keys can't approve anything.
    private func askApproval(_ prompt: String, spoken: String, target: CGPoint? = nil) {
        setAwaiting(true)
        if let target { overlay.point(at: target, label: nil, hold: .infinity) }
        overlay.ask(prompt, touchID: true)
        voice.say(spoken) {}
        if !voice.isSpeaking { NSSound(named: "Tink")?.play() }

        authContext?.invalidate()
        let context = LAContext()
        context.localizedCancelTitle = "Don't"
        authContext = context
        // Fingerprint when Touch ID is available; otherwise (lid closed, no sensor) the account password.
        var error: NSError?
        let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        // macOS shows this as "Buddy is trying to <reason>".
        var reason = prompt.split(separator: "\n").first.map(String.init) ?? prompt
        if reason.hasSuffix("?") { reason.removeLast() }
        reason = reason.prefix(1).lowercased() + reason.dropFirst()
        context.evaluatePolicy(policy, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.authContext === context else { return } // already answered or cancelled
                self.authContext = nil
                ok ? self.runNext() : self.decline()
            }
        }
    }

    /// Runs the next step if it's harmless, otherwise asks first.
    private func nextStep() {
        guard let step = queued.first else { return }
        let level = step.level
        if level == .off {
            queued.removeAll()
            didActions.removeAll()
            overlay.notice("That's turned off in Settings › Permissions.", hideAfter: 4)
            return
        }
        if level != .ask && autoSafe && (step.runsWithoutAsking || (approvedAreas.contains(step.area) && !step.isDestructive)) {
            runNext()
            return
        }
        askApproval(step.action.prompt, spoken: step.action.spoken, target: step.action.target)
    }

    /// A button, shortcut or the close button acted instead of the voice: stop capturing.
    private func stopAnswerCapture() {
        setLocked(false)
        guard answering || talking else { return }
        answering = false
        talking = false
        listener.cancelCapture()
        stopIfNotListening()
    }

    private func runNext() {
        if permission != nil { answerPermission(true); return }
        if pendingCommand != nil { answerCommand(true); return }
        guard let step = queued.first else { return }
        if awaiting { approvedAreas.insert(step.area) } // you OK'd a step: trust more steps like it in this task
        stopAnswerCapture()
        guard !step.action.needsAccessibility || Executor.ensureTrusted() else {
            setAwaiting(true)
            overlay.ask("Allow Buddy under System Settings › Privacy & Security › Accessibility, then press Do it.")
            return
        }
        setAwaiting(false)
        queued.removeFirst()
        stepInFlight = true
        if case .wait = step.action {} else { canvas.clear() } // the screen is about to change
        let thisTurn = turn
        overlay.think(step.action.doing)

        let perform = { [weak self] in
            guard let self, thisTurn == self.turn else { self?.stepInFlight = false; return } // the user started talking: stop
            let problem = Executor.run(step.action)
            self.didActions.append(problem.map { "tried to \(step.action.done) but \($0)" } ?? step.action.done)
            self.steps += 1
            let proceed = {
                self.stepInFlight = false
                guard thisTurn == self.turn else { return }
                self.queued.isEmpty ? self.continueTask() : self.nextStep()
            }
            // Before looking again, let the screen finish changing: about a second if it's already
            // loaded, longer only while it's still loading. Steps in the middle of a batch don't need to.
            let last = self.queued.isEmpty
            switch step.action {
            case let .wait(seconds): ScreenSettle.wait(min: 0.55, max: max(seconds, 1.5), done: proceed)
            case .open: ScreenSettle.wait(min: last ? 0.5 : 0.4, max: last ? 5 : 3, done: proceed)
            case .click where last, .key where last, .press where last, .menu where last: ScreenSettle.wait(min: 0.3, max: 2.5, done: proceed)
            case .click, .key, .press, .menu: DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: proceed)
            default: DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: proceed)
            }
        }
        // Clicks: the buddy flies to the spot and the click lands when it arrives. Accessibility actions
        // don't need the mouse, so they run at once while the buddy shows where. Everything else runs now.
        if case .click = step.action, let target = step.action.target {
            overlay.click(at: target, then: perform)
        } else if let target = step.action.target {
            overlay.point(at: target, label: nil, hold: 0.35, quick: true)
            perform()
        } else {
            overlay.hideBuddy()
            perform()
        }
    }

    /// `open -n -a Buddy --args --demo` walks through every panel state, speaking the answer with the
    /// chosen voice, without the mic or Claude. Useful for design checks; the demo copy quits when done.
    private func runDemo() {
        let after = { (delay: Double, step: @escaping () -> Void) in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: step)
        }
        let args = CommandLine.arguments
        let snapDir = args.firstIndex(of: "--snap").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        let snap = { (name: String, delay: Double) in
            guard let dir = snapDir else { return }
            after(delay) {
                self.overlay.snapshot(name, into: dir)
                // The whole screen as you'd see it, Buddy's windows included (web content doesn't show in the view snapshot).
                let screen = NSScreen.underMouse
                Task { @MainActor in
                    if let shot = try? await ScreenGrabber.capture(frame: screen.frame, displayID: screen.displayID, includingBuddy: true) {
                        try? shot.jpeg.write(to: dir.appendingPathComponent("\(name)-screen.jpg"))
                    }
                }
            }
        }

        let finish = {
            self.voice.onIdle = nil
            after(4) {
                self.overlay.hideBuddy()
                self.overlay.hidePanel()
                snap("5-drawings-left", 1)
                after(2) { self.chatsWindow.show() }
                snap("6-chats", 4)
                after(6) { NSApp.terminate(nil) } // a demo copy runs beside the real Buddy; don't leave it behind
            }
        }
        let confirm = {
            self.voice.onIdle = nil
            let f = NSScreen.underMouse.frame
            self.overlay.point(at: CGPoint(x: f.midX, y: f.midY), label: "Downloads", hold: .infinity)
            self.overlay.ask("Click “Downloads”?")
            NSSound(named: "Tink")?.play()
            snap("4-confirm", 2.5)
            after(1) {
                self.voice.onIdle = finish
                self.voice.say("Want me to click Downloads for you?") {}
                if !self.voice.enabled { finish() }
            }
        }

        after(0.5) { NSSound(named: "Pop")?.play(); self.overlay.listen() }
        after(1.0) { self.overlay.heard("What does this manual say about dispersive power?") }
        snap("1-listening", 2.5)
        after(4.0) { self.overlay.think("Searching your Drive…"); self.voice.prepare() }
        snap("2-thinking", 5.5)
        after(6.5) {
            let answer = [
                "Angular dispersive power is how quickly the diffraction angle changes with wavelength.",
                "It gets larger in higher orders, so second-order lines spread out more.",
            ]
            var shown = ""
            let f = NSScreen.underMouse.frame
            self.canvas.draw([.circle(CGRect(x: f.width * 0.3, y: f.height * 0.45, width: 220, height: 40), label: "This one", color: nil)], shot: nil)
            self.overlay.board("""
            # Grating equation
            For a grating with spacing $d$, the bright lines satisfy
            $$d \\sin\\theta = m\\lambda$$
            1. Differentiate with respect to $\\lambda$:
            $$d\\cos\\theta \\, \\frac{d\\theta}{d\\lambda} = m$$
            2. So the angular dispersive power is
            $$D = \\frac{d\\theta}{d\\lambda} = \\frac{m}{d\\cos\\theta}$$
            3. It grows with the order $m$, so **second-order lines spread out more**.
            """)
            // A follow-up, no wake word: it becomes the next turn of the chat.
            let followUp = {
                self.voice.onIdle = nil
                self.overlay.followUp()
                after(1.2) { self.overlay.heard("Why does it grow with the order?") }
                after(2.4) { self.overlay.think("Thinking…") }
                after(3.4) {
                    self.voice.onIdle = { after(0.6, confirm) }
                    let line = "Higher orders bend the light further, so the same change in wavelength moves the line through a bigger angle."
                    self.voice.say(line) { self.overlay.say(line) }
                    if !self.voice.enabled { self.overlay.say(line); after(4, confirm) }
                }
                snap("3b-followup", 7)
            }
            self.voice.onIdle = { after(0.6, followUp) }
            for sentence in answer {
                self.voice.say(sentence) {
                    shown += (shown.isEmpty ? "" : " ") + sentence
                    self.overlay.say(shown)
                }
            }
            if !self.voice.enabled { after(5, followUp) }
        }
        snap("3-speaking", 11)
    }

    /// `open -n -a Buddy --args --scene scene.json` stages one exchange, without the mic, Claude or the
    /// voice, for screenshots like the README's. The reply goes through the real ReplyParser, so it uses
    /// Claude's own tags, with coordinates in points from the top left of the screen under the mouse:
    ///   {"question": "…", "reply": "Sentence. [CIRCLE:x,y,w,h:label] [BOARD]…[/BOARD]",
    ///    "confirm": "Send this email to Priya?", "hold": 30}
    /// `confirm` shows the Needs your OK card (its buttons do nothing). Quits after `hold` seconds.
    private func runScene(_ file: URL) {
        guard let data = try? Data(contentsOf: file),
              let scene = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("error: can't read scene \(file.path)")
            NSApp.terminate(nil)
            return
        }
        let after = { (delay: Double, step: @escaping () -> Void) in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: step)
        }
        let f = NSScreen.underMouse.frame
        let shot = Shot(jpeg: Data(), width: Int(f.width), height: Int(f.height), frame: f)
        var chunks: [ReplyParser.Chunk] = []
        let parser = ReplyParser { chunks.append($0) }
        parser.feed(scene["reply"] as? String ?? "")
        parser.finish()

        overlay.listen()
        after(0.3) { self.overlay.heard(scene["question"] as? String ?? "") }
        after(0.8) { self.overlay.think("Thinking…") }
        after(1.4) {
            var said = ""
            for chunk in chunks {
                for mark in chunk.marks {
                    if case let .board(_, _, text) = mark { self.overlay.board(text) } else { self.canvas.draw([mark], shot: shot) }
                }
                for p in chunk.points { self.overlay.point(at: shot.toScreen(CGPoint(x: p.x, y: p.y)), label: p.label, hold: .infinity) }
                if !chunk.text.isEmpty { said += (said.isEmpty ? "" : " ") + chunk.text }
            }
            if !said.isEmpty { self.overlay.say(said) }
            if let question = scene["confirm"] as? String { after(0.6) { self.overlay.ask(question) } }
        }
        after(scene["hold"] as? Double ?? 30) { NSApp.terminate(nil) }
    }

    /// The panel's close button: stop talking and drop anything pending.
    private func closePanel() {
        stopAnswerCapture()
        followingUp = false
        stepInFlight = false
        turn += 1
        voice.stop()
        claude.cancel()
        permission = nil
        cancelCommand()
        setAwaiting(false)
        queued.removeAll()
        didActions.removeAll()
        canvas.clear()
        overlay.hideBuddy()
        overlay.hidePanel()
    }

    private func decline() {
        if permission != nil { answerPermission(false); return }
        if pendingCommand != nil { answerCommand(false); return }
        stopAnswerCapture()
        setAwaiting(false)
        queued.removeAll()
        didActions.removeAll()
        overlay.hideBuddy()
        overlay.notice("Okay, I won't.", hideAfter: 2)
    }

    /// After confirmed actions run, show Claude the new screen so it can take the next step.
    private func continueTask() {
        let done = didActions.joined(separator: "; ")
        didActions.removeAll()
        guard steps < maxSteps else {
            overlay.notice("Stopping here after \(steps) steps. Ask me to keep going if you want.", hideAfter: 6)
            return
        }
        turn += 1
        parser.reset()
        reply = ""
        taskTurn = true
        sawAction = false
        streamingSpeech = false
        heldText = []
        overlay.think("Working…")
        let (capture, mouse) = captureScreen()
        send(capture: capture, mouse: mouse, turn: turn) { shot, m in
            """
            [Done: \(done).] Updated screenshot attached: \(shot.width)x\(shot.height) px. Mouse at (\(Int(m.x)), \(Int(m.y))).
            If the task isn't finished, take the next step: action tags only, no words. If it is finished, or you need something from me, say so in one short sentence with no actions.
            """
        }
    }

    // MARK: Menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Buddy")

        let menu = NSMenu()
        let ask = NSMenuItem(title: "Ask Buddy", action: #selector(askNow), keyEquivalent: "")
        ask.target = self
        menu.addItem(ask)
        let hold = NSMenuItem(title: "Listen Until Return", action: #selector(lockFromMenu), keyEquivalent: "l")
        hold.keyEquivalentModifierMask = [.control, .option]
        hold.target = self
        menu.addItem(hold)
        let wake = NSMenuItem(title: "Listen for “Hey Buddy”", action: #selector(toggleWake(_:)), keyEquivalent: "")
        wake.target = self
        wake.state = wakeEnabled ? .on : .off
        menu.addItem(wake)
        let engine = NSMenuItem(title: Whisper.available ? "Speech-to-text: Whisper (local)" : "Speech-to-text: Apple", action: nil, keyEquivalent: "")
        engine.isEnabled = false
        menu.addItem(engine)
        menu.addItem(.separator())

        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        for (title, id) in models {
            let item = NSMenuItem(title: title, action: #selector(pickModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = id == claude.model ? .on : .off
            modelMenu.addItem(item)
        }
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        let voiceItem = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        let voiceMenu = NSMenu()
        let choices = (KokoroTTS.available ? KokoroTTS.voices : []) + [("Apple (system voice)", "apple")]
        for (title, id) in choices {
            let item = NSMenuItem(title: title, action: #selector(pickVoice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = id == voice.voiceID || (!KokoroTTS.available && id == "apple") ? .on : .off
            voiceMenu.addItem(item)
        }
        voiceItem.submenu = voiceMenu
        menu.addItem(voiceItem)

        let speak = NSMenuItem(title: "Speak replies", action: #selector(toggleSpeak(_:)), keyEquivalent: "")
        speak.target = self
        speak.state = voice.enabled ? .on : .off
        menu.addItem(speak)

        let auto = NSMenuItem(title: "Do safe actions without asking", action: #selector(toggleAutoSafe(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = autoSafe ? .on : .off
        menu.addItem(auto)

        let fresh = NSMenuItem(title: "New conversation", action: #selector(newConversation), keyEquivalent: "n")
        fresh.target = self
        menu.addItem(fresh)

        let chats = NSMenuItem(title: "Chats…", action: #selector(openChats), keyEquivalent: "")
        chats.target = self
        menu.addItem(chats)

        let settings = NSMenuItem(title: "Features & Permissions…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let wipe = NSMenuItem(title: "Clear drawings", action: #selector(clearDrawings), keyEquivalent: "")
        wipe.target = self
        menu.addItem(wipe)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Buddy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// Talk without the wake phrase.
    @objc private func askNow() {
        if !listener.running { startListening() }
        guard listener.running else { return }
        beginTalking()
        listener.listenNow()
    }

    @objc private func lockFromMenu() { toggleLockedListening() }

    @objc private func toggleWake(_ sender: NSMenuItem) {
        wakeEnabled.toggle()
        sender.state = wakeEnabled ? .on : .off
        defaults.set(wakeEnabled, forKey: "wake")
        if wakeEnabled {
            startListening()
        } else if !talking && !awaiting {
            listener.stop()
        }
    }

    @objc private func pickModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        sender.menu?.items.forEach { $0.state = $0 == sender ? .on : .off }
        defaults.set(id, forKey: "model")
        claude.setModel(id)
        permission = nil
        cancelCommand()
    }

    @objc private func pickVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        sender.menu?.items.forEach { $0.state = $0 == sender ? .on : .off }
        defaults.set(id, forKey: "voice")
        voice.stop()
        voice.voiceID = id
        voice.prepare()
        voice.say(id == "apple" ? "This is the system voice." : "Hi, this is how I sound.") {}
    }

    @objc private func toggleSpeak(_ sender: NSMenuItem) {
        voice.enabled.toggle()
        if !voice.enabled { voice.stop() }
        sender.state = voice.enabled ? .on : .off
        defaults.set(voice.enabled, forKey: "speak")
    }

    @objc private func toggleAutoSafe(_ sender: NSMenuItem) {
        autoSafe.toggle()
        sender.state = autoSafe ? .on : .off
        defaults.set(autoSafe, forKey: "autoSafe")
    }

    @objc private func clearDrawings() { canvas.clear() }

    @objc private func openChats() { chatsWindow.show() }

    @objc private func openSettings() { showSettings("features") }

    private func showSettings(_ section: String) {
        settingsWindow.authorize = { [weak self] reason, approved in self?.touchID(reason, then: approved) }
        settingsWindow.onChange = { [weak self] in self?.commandSettingsChanged() }
        settingsWindow.show(section)
    }

    /// Touch ID (or the account password) for a change made in the Settings window. `then` runs only on a yes.
    private func touchID(_ reason: String, then approved: @escaping () -> Void) {
        let context = LAContext()
        context.localizedCancelTitle = "Don't"
        var error: NSError?
        let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        context.evaluatePolicy(policy, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { if ok { approved() } }
        }
    }

    @objc private func newConversation() {
        stopAnswerCapture()
        stepInFlight = false
        turn += 1
        voice.stop()
        setAwaiting(false)
        queued.removeAll()
        didActions.removeAll()
        claude.newConversation()
        permission = nil
        cancelCommand()
        chatLog.startNew()
        canvas.clear()
        overlay.hidePanel() // the next question starts a fresh chat
        overlay.notice("Fresh start", hideAfter: 1.5)
    }
}

// MARK: - The `buddy` CLI (see Commands.swift)

extension AppDelegate: CommandHost {
    private static let screenshotDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Buddy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func commandScreenshot(controls wantControls: Bool, reply: @escaping (String) -> Void) {
        let (capture, mouse) = captureScreen()
        let tree = wantControls ? Task.detached { AXTree.snapshot() } : nil
        Task { @MainActor in
            do {
                let shot = try await capture.value
                let controls = await tree?.value
                self.shot = shot // later coordinates refer to this screenshot
                if wantControls { self.controls = controls }
                let url = try Self.save(shot)
                let m = shot.toImage(mouse)
                var out = "Screenshot saved to \(url.path) (\(shot.width)x\(shot.height) px; read it to see the screen). Mouse at (\(Int(m.x)), \(Int(m.y)))."
                if let listing = controls?.listing(in: shot), !listing.isEmpty { out += "\n" + listing }
                reply(out)
            } catch {
                reply("error: screen capture failed. Buddy needs Screen Recording permission.")
            }
        }
    }

    /// Saves under ~/Library/Caches/Buddy, keeping only the last few.
    private static func save(_ shot: Shot) throws -> URL {
        let fm = FileManager.default
        let old = ((try? fm.contentsOfDirectory(at: screenshotDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("screen-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in old.dropLast(4) { try? fm.removeItem(at: file) }
        let url = screenshotDir.appendingPathComponent("screen-\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
        try shot.jpeg.write(to: url)
        return url
    }

    func commandControls(reply: @escaping (String) -> Void) {
        guard let shot else { commandScreenshot(controls: true, reply: reply); return }
        Task { @MainActor in
            let controls = await Task.detached { AXTree.snapshot() }.value
            self.controls = controls
            let listing = controls?.listing(in: shot) ?? ""
            reply(listing.isEmpty ? "No controls found (is Accessibility allowed for Buddy?)." : listing)
        }
    }

    func commandStep(_ step: Step, reply: @escaping (String) -> Void) {
        if case .click = step.action, shot == nil { reply("error: run `buddy screenshot` first, so coordinates mean something"); return }
        let toScreen: (CGPoint) -> CGPoint = { [shot] p in shot?.toScreen(p) ?? p }
        let step = step.mapped(toScreen).resolved(controls)
        guard !awaiting else { reply("error: Buddy is already waiting for the user's answer to another step"); return }
        // The same rules as reply tags: harmless steps run, risky ones ask; after one yes the rest of the
        // request runs, except destructive steps. "Always ask" in Settings asks for every step.
        let level = step.level
        if level == .off { reply("error: that \(BuddyCommands.turnedOff)"); return }
        if level != .ask && autoSafe && (step.runsWithoutAsking || (approvedAreas.contains(step.area) && !step.isDestructive)) {
            perform(step, reply: reply)
            return
        }
        pendingCommand = ({ [weak self] in self?.perform(step, reply: reply) }, reply, step.area)
        askApproval(step.action.prompt, spoken: step.action.spoken, target: step.action.target)
    }

    func commandApproval(prompt: String, spoken: String, approved: @escaping () -> Void, reply: @escaping (String) -> Void) {
        guard !awaiting else { reply("error: Buddy is already waiting for the user's answer to another step"); return }
        pendingCommand = (approved, reply, nil) // a settings change or feature run: its yes covers only itself
        askApproval(prompt, spoken: spoken)
    }

    /// The user answered the OK card for a CLI step.
    private func answerCommand(_ allow: Bool) {
        guard let (approve, reply, area) = pendingCommand else { return }
        pendingCommand = nil
        stopAnswerCapture()
        setAwaiting(false)
        overlay.hideBuddy()
        if allow {
            if let area { approvedAreas.insert(area) }
            overlay.think("Working on it…") // the card goes away as soon as you've approved
            approve()
        } else {
            overlay.think("Okay, skipping that…")
            reply("declined: the user didn't approve it. Don't try it another way; tell them briefly.")
        }
    }

    /// A new request, the close button or a new conversation: the waiting step won't happen.
    private func cancelCommand() {
        guard let (_, reply, _) = pendingCommand else { return }
        pendingCommand = nil
        reply("declined: cancelled by the user")
    }

    /// Runs a step, then waits for the screen to settle so the next screenshot shows the result.
    private func perform(_ step: Step, reply: @escaping (String) -> Void) {
        guard !step.action.needsAccessibility || Executor.ensureTrusted() else {
            reply("error: Buddy needs Accessibility permission (System Settings › Privacy & Security › Accessibility)")
            return
        }
        canvas.clear() // the screen is about to change
        overlay.think(step.action.doing)
        let go = { [self] in
            // Synthetic clicks hit the topmost window, so let them through the chat panel.
            overlay.passThrough(true)
            let problem = Executor.run(step.action)
            let done = {
                self.overlay.passThrough(false)
                reply(problem.map { "error: tried to \(step.action.done) but \($0)" } ?? "ok: \(step.action.done)")
            }
            switch step.action {
            case .open: ScreenSettle.wait(min: 0.5, max: 5, done: done)
            case .click, .key, .press, .menu, .set, .type: ScreenSettle.wait(min: 0.3, max: 2.5, done: done)
            default: DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: done)
            }
        }
        if case .click = step.action, let target = step.action.target {
            overlay.click(at: target, then: go)
        } else if let target = step.action.target {
            overlay.point(at: target, label: nil, hold: 0.35, quick: true)
            go()
        } else {
            go()
        }
    }

    func commandSettingsChanged() {
        settingsWindow.refresh()
        claude.refreshSettings() // the feature list is part of Claude's prompt
    }

    func commandShowSettings(_ section: String) { showSettings(section) }

    func commandDraw(_ marks: [Mark], reply: @escaping (String) -> Void) {
        canvas.draw(marks, shot: shot)
        reply("ok: drawn")
    }

    func commandPoint(_ p: CGPoint, label: String?, reply: @escaping (String) -> Void) {
        guard let shot else { reply("error: run `buddy screenshot` first"); return }
        overlay.point(at: shot.toScreen(p), label: label)
        reply("ok: pointing")
    }

    func commandWait(_ seconds: Double, reply: @escaping (String) -> Void) {
        ScreenSettle.wait(min: 0.55, max: seconds) { reply("ok: the screen has settled") }
    }

    func commandCards(_ new: [ResultCard], reply: @escaping (String) -> Void) {
        cards += new
        overlay.addCards(new)
        reply("ok: shown \(new.count) card\(new.count == 1 ? "" : "s")")
    }

    func commandBoard(_ text: String, reply: @escaping (String) -> Void) {
        board = text
        overlay.board(text)
        reply("ok: shown in the chat panel")
    }
}
