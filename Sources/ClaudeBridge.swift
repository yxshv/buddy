import Foundation

/// Talks to Claude through the `claude` CLI (Claude Code) in headless stream-json mode,
/// so requests run on your Claude Pro/Max subscription login instead of an API key.
/// One long-lived process holds the conversation; it is restarted with --resume when needed.
final class ClaudeBridge {
    var model = "sonnet"
    var onText: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onTurnEnd: ((String?) -> Void)?
    /// Claude is about to use a tool (name), e.g. to drop narration said before it.
    var onToolUse: ((String) -> Void)?
    /// Claude Code wants to use a tool that isn't read-only; answer with `answer(_:allow:)`.
    var onPermission: ((ToolPermission) -> Void)?
    private(set) var busy = false
    let claudePath = ClaudeBridge.findClaude()

    private var process: Process?
    private var input: FileHandle?
    private var generation = 0
    private var sessionId: String?
    private var streamedThisTurn = false
    private var stderrTail = ""
    private let workDir: URL

    static var systemPrompt: String { """
    You are Buddy, a friendly, sharp helper that lives next to the user's mouse cursor on their Mac. \
    With every message you get a screenshot of the screen they're looking at and what they said out loud \
    (speech-to-text, so expect small transcription mistakes).

    Your reply is read aloud by text-to-speech. Be brief: answer exactly what was asked, usually in one \
    sentence, never more than two unless they explicitly ask for steps or an explanation. Do what is \
    asked and nothing more: no preamble, no restating the question, no extra tips, caveats, follow-up \
    offers or "let me know if…". No markdown, bullet points, code blocks, emoji, or long URLs. \
    Only use a BOARD when they ask for an explanation, steps or math, and keep it short too.

    When it helps to show them where something is, point at it with a tag [POINT:x,y:label] where x,y are \
    pixel coordinates in the screenshot (origin top-left) of the exact spot to click, and label is 1-3 words. \
    Put the tag right before the sentence that talks about that element; tags are not read aloud. For \
    multi-step instructions use one tag per step, in order. Only point at things actually visible in the \
    screenshot. If you can't tell what they mean, ask a short question.

    You also have a canvas: a transparent layer over their screen that you can draw and write on, like a \
    teacher marking up the page. Use it when showing beats telling: circle what they asked about, point an \
    arrow at where to look. Drawing tags (not read aloud; \
    coordinates are screenshot pixels, x,y,w,h is the thing's bounding box with x,y its top-left corner):
    [CIRCLE:x,y,w,h:label] circles it; [BOX:x,y,w,h:label] puts a rounded box around it;
    [ARROW:x1,y1,x2,y2:label] an arrow from x1,y1 pointing at x2,y2, label at the tail (start it in empty space);
    [UNDERLINE:x1,y,x2] underlines text whose baseline is at y; [HIGHLIGHT:x,y,w,h] a highlighter wash over text;
    [NOTE:x,y]text[/NOTE] a small card beside x,y for a short remark or formula;
    [CLEAR] wipes the canvas.
    For anything longer (explanations, proofs, derivations, worked steps, formulas), write it in \
    [BOARD]text[/BOARD]: it appears in Buddy's chat panel under your spoken words, which scrolls and \
    keeps the conversation history.
    Labels are optional, 1-4 words. Add a color at the end of a tag: |blue, |green, |orange, |purple or \
    |yellow (red is the default), e.g. [CIRCLE:300,200,80,24:This one|blue]; use different colors to tell \
    things apart. NOTE and BOARD text supports Markdown (# heading, **bold**, - lists, 1. steps) and LaTeX: \
    $...$ inline and $$...$$ on its own line. Write math only in NOTE or BOARD; out loud, say it in words and \
    keep it short: give the gist and let the board hold the details. Use one BOARD per reply. \
    Circles, arrows and notes are wiped when they say "Hey Buddy" again or when you take an action. \
    Put drawing tags before the sentence that talks about them.

    When the user is wrapping up ("thanks, that's all", "I'll continue later", "got it"), reply with a very \
    short goodbye and add [END], so Buddy stops listening for a follow-up.

    You run inside Claude Code on the user's Mac, in their home folder, with all your usual tools: Bash, \
    reading and editing files, web search, and MCP servers for their Obsidian vault, Google Drive, Gmail, \
    Google Calendar, Todoist and more (find them with ToolSearch). Use them to actually get things done: \
    find their projects and run their commands, read and edit notes and files, look things up. When a tool \
    can do it directly, prefer it over clicking around the screen. When they ask about a file, email, \
    event, task or note, including one visible on screen, find it and read it instead of saying you can't. \
    Buddy itself asks the user before anything that changes things (commands, edits, sending, deleting), \
    so never ask for permission in words: just call the tool, and if they decline, say so in a sentence. \
    Say one very short sentence before a lookup or task, like "Let me check your Drive." Never read out \
    command output, file paths or code: say what happened in a sentence or two.

    When a task changes something (creates, edits, sends, schedules, publishes or deletes anything: a \
    calendar event, a file, a note, an email, a task), show each thing it changed as a card the user can \
    click to open: `buddy card "<title>" --subtitle "<what happened, e.g. Added · Wed 9-10 pm>" --url \
    <its link, or a file path> --kind <note|calendar|file|email|task|link>`, one per thing (use the event's \
    or email's web link from the tool's result). `buddy obsidian publish` makes its own cards. Never make \
    cards for lookups or plain answers. When cards are shown, the cards are the answer: reply with just \
    "Done." and don't describe what changed. Add one short sentence only for something the user must \
    know, like a guess you made ("I guessed it ends at 10.") or something still missing.

    Never change the user's own code unless they explicitly ask you to edit it, and never change their \
    competitive-programming code at all (\(Permissions.protectedFolders.joined(separator: ", "))), even if they \
    say "fix it": Buddy refuses those edits anyway. When they ask you to check, test or run it, only report what happened \
    in a sentence: don't explain the bug or fix it. If they say a result is wrong, or say "fix it" about \
    your checking, the problem is in your tool or your reading of it, not in their code: say so and stop.

    You have memory (Claude Code's memory files). When the user teaches you how they do something (like \
    how they publish their Obsidian notes, or where a project lives) or asks you to remember something, \
    save it to memory without asking, so you know it next time. When a request sounds like something \
    they've taught you before, check your memory first.

    To operate their computer, use the `buddy` command through Bash; it's always available. Run \
    `buddy help` the first time: it lists every capability and which ones ask the user first (they approve \
    with Touch ID). It also browses and reads files (`buddy files`, `buddy read`) and publishes their \
    Obsidian notes (`buddy obsidian publish NOTE`). Coordinates are pixels of the screenshot attached to the message, or of your \
    latest `buddy screenshot`. Work in a loop inside your turn: act, then `buddy screenshot` and Read the \
    image to see what happened, then the next step, until the task is done. Each action returns only once \
    the screen has settled, so wait separately (`buddy wait 3`) only while something is still loading. \
    Messages often list the controls in the app in front, read from macOS accessibility, as lines like \
    #12 button "Delete" @412,88 (@ is its center in screenshot pixels), plus its menu names; \
    `buddy screenshot` refreshes that list. When the control you want is listed, use `buddy press 12`, \
    `buddy set 7 new text` or `buddy menu "File>Save As…"` instead of clicking: it's faster and never misses. \
    Numbers only refer to the latest list. Run several commands in one Bash call, joined with &&, when \
    you can predict the outcome, e.g. buddy click 300 40 --label Search && buddy type lofi beats && buddy key return --safe.
    Buddy applies safety itself: everyday, easily undone steps just run (opening, navigating, selecting, \
    ticking checkboxes, toggling, typing into fields), and risky ones ask the user on the OK card first \
    (deleting, sending or submitting anything to other people, posting, sharing, buying, paying, changing \
    account or system settings, anything hard to undo). Add --confirm to a step that is risky in a way \
    Buddy can't tell from its label. Return could send a message, so add --safe to a Return that only \
    submits a search or URL. If a command prints "declined", don't try another way: say so in a sentence. \
    While you talk, keep using the drawing and [POINT] tags above, which are timed with your speech; \
    mid-task, `buddy circle`, `buddy arrow`, `buddy note`, `buddy point` and `buddy board` do the same.
    Only use actions when they ask you to do something, not when they ask how. While doing a task, work \
    silently: no narration like "I'll click Save" (the app shows what you're doing and asks the user \
    itself before risky steps). Use words only when you need something \
    from the user, or when the task is finished. \
    Be fast: chain every step whose result you can already predict into one Bash call, and only take a \
    fresh screenshot when you need to see the outcome to choose the next step. Prefer the shortest route: a direct link to the result \
    (like a search or channel URL), or a keyboard shortcut, over clicking through menus. Finish the whole task by yourself: never stop to ask \
    the user to wait, say "continue" or do a step you can do. If something is still loading, run \
    `buddy wait 3` and keep going. Stop early only if you truly need their input (like which of two options they mean). Prefer keyboard shortcuts and `buddy open` over clicking when they're reliable. Never delete, \
    send, buy, share, or enter passwords or payment details unless they asked for exactly that.
    """ }

    /// Connector lookups that never need asking (anything that sends, edits or deletes asks first).
    static let readOnlyTools = [
        "mcp__claude_ai_Google_Drive__search_files",
        "mcp__claude_ai_Google_Drive__list_recent_files",
        "mcp__claude_ai_Google_Drive__get_file_metadata",
        "mcp__claude_ai_Google_Drive__read_file_content",
        "mcp__claude_ai_Google_Drive__download_file_content",
        "mcp__claude_ai_Gmail__search_threads",
        "mcp__claude_ai_Gmail__get_thread",
        "mcp__claude_ai_Gmail__get_message",
        "mcp__claude_ai_Gmail__list_labels",
        "mcp__claude_ai_Google_Calendar__list_calendars",
        "mcp__claude_ai_Google_Calendar__list_events",
        "mcp__claude_ai_Google_Calendar__get_event",
        "mcp__claude_ai_Google_Calendar__search_events",
        "mcp__claude_ai_Todoist__find-tasks",
        "mcp__claude_ai_Todoist__find-tasks-by-date",
        "mcp__claude_ai_Todoist__find-projects",
        "mcp__claude_ai_Todoist__get-overview",
    ]

    /// Short status line for a tool call, shown in the bubble while Claude looks something up.
    static func status(forTool name: String) -> String {
        if name.contains("Google_Drive") { return "Searching your Drive…" }
        if name.contains("Gmail") { return "Checking your email…" }
        if name.contains("Calendar") { return "Checking your calendar…" }
        if name.contains("Todoist") { return "Checking your tasks…" }
        if name.contains("obsidian") { return "Checking your notes…" }
        switch name {
        case "Bash": return "Running a command…"
        case "Read", "Glob", "Grep": return "Looking through your files…"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "Editing a file…"
        case "WebSearch", "WebFetch": return "Searching the web…"
        case "Task", "Agent": return "Working on it…"
        default: return "Looking that up…"
        }
    }

    init() {
        // Your home folder, so Claude can find your projects (and keeps one memory for Buddy).
        workDir = FileManager.default.homeDirectoryForCurrentUser
    }

    func warmUp() { _ = ensureProcess() }

    /// What the running process was started with: the features in its prompt and its allow-list.
    private var startedWith = ""
    private static var settingsSignature: String { FeatureStore.signature + "\n" + Permissions.shared.signature }

    /// Features or permissions changed: restart (keeping the conversation) before the next question.
    func refreshSettings() {
        guard process != nil, !busy, startedWith != Self.settingsSignature else { return }
        kill()
        warmUp()
    }

    /// `jpeg` is nil when "Look at the screen" is off in Settings.
    func send(text: String, jpeg: Data?) {
        refreshSettings()
        guard let input = ensureProcess() else {
            onTurnEnd?("Couldn't start the claude CLI.")
            return
        }
        let message: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": (jpeg.map { [["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0.base64EncodedString()]]] } ?? [])
                    + [["type": "text", "text": text]],
            ],
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        busy = true
        streamedThisTurn = false
        do {
            try input.write(contentsOf: data)
        } catch {
            kill()
            onTurnEnd?("Lost the connection to claude. Try again.")
        }
    }

    /// Answers a permission request from `onPermission`.
    func answer(_ request: ToolPermission, allow: Bool, because reason: String = "The user declined this.") {
        let reply: [String: Any] = allow
            ? ["behavior": "allow", "updatedInput": request.input]
            : ["behavior": "deny", "message": "\(reason) Don't try it another way; tell them briefly."]
        write(["type": "control_response",
               "response": ["subtype": "success", "request_id": request.id, "response": reply]])
    }

    private func write(_ object: [String: Any]) {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        try? input.write(contentsOf: data)
    }

    /// Abandons the current reply (keeps the conversation).
    func cancel() { if busy { kill() } }

    func newConversation() {
        kill()
        sessionId = nil
        warmUp()
    }

    func setModel(_ m: String) {
        model = m
        kill()
        warmUp()
    }

    private func kill() {
        generation += 1
        busy = false
        process?.terminate()
        process = nil
        input = nil
    }

    private func ensureProcess() -> FileHandle? {
        if let input, process?.isRunning == true { return input }
        guard let claudePath else { return nil }

        generation += 1
        let gen = generation
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudePath)
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", model,
            // All of Claude Code's tools. Read-only ones just run; anything else comes back to Buddy as a
            // permission request (control_request "can_use_tool") and waits for your OK.
            "--permission-mode", "default",
            // No settings files: allow rules or hooks in ~/.claude/settings*.json would approve tools before
            // Buddy is asked, and Claude could write them. Buddy's own rules are the only ones.
            "--setting-sources", "",
            "--permission-prompt-tool", "stdio",
            "--allowedTools", Permissions.shared.allowedTools.joined(separator: ","),
            "--disallowedTools", ToolPermission.disallowed.joined(separator: ","),
            // Keep Claude Code's own prompt (tools, memory, CLAUDE.md) and add Buddy's on top.
            "--append-system-prompt", Self.systemPrompt + FeatureStore.prompt(),
        ]
        startedWith = Self.settingsSignature
        if let sessionId { args += ["--resume", sessionId] }
        p.arguments = args
        p.currentDirectoryURL = workDir

        var env = ProcessInfo.processInfo.environment
        // Make sure the CLI uses the subscription login, not API-key billing.
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "CLAUDECODE")
        let home = NSHomeDirectory()
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        var lineBuffer = Data()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            lineBuffer.append(chunk)
            while let newline = lineBuffer.firstIndex(of: 0x0A) {
                let line = lineBuffer[lineBuffer.startIndex..<newline]
                lineBuffer = Data(lineBuffer[lineBuffer.index(after: newline)...])
                guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                DispatchQueue.main.async { self?.handle(obj, gen: gen) }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(decoding: chunk, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + text).suffix(600))
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                let wasBusy = self.busy
                self.process = nil
                self.input = nil
                self.busy = false
                self.sessionId = nil // an unexpected exit often means the session can't be resumed
                let detail = self.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                if wasBusy { self.onTurnEnd?(detail.isEmpty ? "claude exited unexpectedly." : String(detail.suffix(200))) }
            }
        }

        do { try p.run() } catch { return nil }
        process = p
        input = inPipe.fileHandleForWriting
        // Say we're the host that answers permission requests.
        write(["type": "control_request", "request_id": "init-\(gen)", "request": ["subtype": "initialize"]])
        return input
    }

    private func handle(_ obj: [String: Any], gen: Int) {
        guard gen == generation else { return }
        if let sid = obj["session_id"] as? String { sessionId = sid }

        switch obj["type"] as? String {
        case "stream_event":
            if let event = obj["event"] as? [String: Any],
               event["type"] as? String == "content_block_start",
               let block = event["content_block"] as? [String: Any],
               block["type"] as? String == "tool_use",
               let name = block["name"] as? String {
                // Text before a tool call ends a sentence; flush it.
                onText?("\n")
                onToolUse?(name)
                onStatus?(name == "ToolSearch" ? "Looking that up…" : Self.status(forTool: name))
            } else if let event = obj["event"] as? [String: Any],
               event["type"] as? String == "content_block_delta",
               let delta = event["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                streamedThisTurn = true
                onText?(text)
            }
        case "assistant":
            // Fallback when no partial deltas arrived (e.g. synthetic error messages).
            guard !streamedThisTurn,
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { break }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            if !text.isEmpty {
                streamedThisTurn = true
                onText?(text)
            }
        case "control_request":
            guard let id = obj["request_id"] as? String, let request = obj["request"] as? [String: Any],
                  request["subtype"] as? String == "can_use_tool", let tool = request["tool_name"] as? String else { break }
            onPermission?(ToolPermission(id: id, tool: tool, input: request["input"] as? [String: Any] ?? [:],
                                         description: request["description"] as? String))
        case "result":
            busy = false
            let failed = obj["is_error"] as? Bool == true && !streamedThisTurn
            onTurnEnd?(failed ? (obj["result"] as? String ?? "Claude returned an error.") : nil)
        default:
            break
        }
    }

    static func findClaude() -> String? {
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return path }

        // Fall back to the user's login shell PATH.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }
}
