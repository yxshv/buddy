import Foundation

/// Claude Code asking to use one of its own tools (run a command, edit a file, change a note…) that
/// isn't on the read-only list. Buddy shows it on the "Needs your OK" card and answers for you.
struct ToolPermission {
    let id: String
    let tool: String
    let input: [String: Any]
    let description: String?

    /// Tools that only look: these never ask. Everything else (Bash beyond these commands, editing files,
    /// sending, creating, deleting in any connector) asks first.
    static let readOnly: [String] = [
        "ToolSearch", "Read", "Glob", "Grep", "WebSearch", "WebFetch", "TodoWrite",
        "Bash(ls:*)", "Bash(pwd)", "Bash(cat:*)", "Bash(head:*)", "Bash(tail:*)", "Bash(wc:*)", "Bash(which:*)",
        "Bash(mdfind:*)", "Bash(file:*)", "Bash(stat:*)", "Bash(date)", "Bash(git status:*)", "Bash(git log:*)",
        "Bash(git diff:*)", "Bash(git branch:*)", "Bash(git remote:*)",
        // Buddy's own CLI: it applies Buddy's safety rules itself and asks on the OK card when needed.
        "Bash(buddy:*)",
        // Claude Code's memory, so it can remember how you do things without asking each time.
        "Write(~/.claude/projects/**/memory/**)", "Edit(~/.claude/projects/**/memory/**)",
        "mcp__obsidian__vault_read", "mcp__obsidian__vault_list", "mcp__obsidian__vault_get_document_map",
        "mcp__obsidian__search_simple", "mcp__obsidian__search_query", "mcp__obsidian__tag_list",
        "mcp__obsidian__active_file_get_path", "mcp__obsidian__periodic_note_get_path",
        "mcp__obsidian__command_list", "mcp__obsidian__open_file",
    ] + ClaudeBridge.readOnlyTools

    /// Tools that make no sense with nobody at a terminal.
    static let disallowed = ["AskUserQuestion", "EnterPlanMode", "ExitPlanMode"]

    private var command: String { input["command"] as? String ?? "" }
    private var path: String? { (input["file_path"] ?? input["path"] ?? input["filename"] ?? input["notebook_path"]) as? String }
    private var fileName: String { path.map { ($0 as NSString).lastPathComponent } ?? "a file" }

    /// "Obsidian" from "mcp__obsidian__vault_patch", "Gmail" from "mcp__claude_ai_Gmail__send".
    private var server: String? {
        guard tool.hasPrefix("mcp__") else { return nil }
        let name = tool.dropFirst(5).components(separatedBy: "__").first ?? ""
        return name.replacingOccurrences(of: "claude_ai_", with: "").replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// "vault patch" from "mcp__obsidian__vault_patch".
    private var action: String {
        (tool.components(separatedBy: "__").last ?? tool).replacingOccurrences(of: #"[_-]"#, with: " ", options: .regularExpression)
    }

    /// The question on the card.
    var prompt: String {
        switch tool {
        case "Bash": return "Run this command?\n\(command.count > 220 ? String(command.prefix(220)) + "…" : command)"
        case "Write": return "Create or replace \(fileName)?"
        case "Edit", "MultiEdit", "NotebookEdit": return "Edit \(fileName)?"
        default:
            if let server {
                let what = path.map { " (\(($0 as NSString).lastPathComponent))" } ?? ""
                return "\(server): \(action)\(what)?"
            }
            return "Use \(tool)?"
        }
    }

    /// What Buddy asks out loud: short, no paths or code.
    var spoken: String {
        if let description, !description.isEmpty {
            return "Can I \(description.prefix(1).lowercased() + description.dropFirst())?"
        }
        switch tool {
        case "Bash": return "Can I run a command for that?"
        case "Write", "Edit", "MultiEdit", "NotebookEdit": return "Can I edit \(fileName)?"
        default: return server.map { "Can I \(action) in \($0)?" } ?? "Can I go ahead?"
        }
    }

    /// Buddy's own settings and features, and Claude Code's settings: changing them asks every time. A regex
    /// over a command can be dodged, so this is only a speed bump: permissions.json is signed with a replay
    /// counter, features run only with an approved hash, and Claude Code runs without settings files.
    var touchesBuddySettings: Bool {
        let sensitive = #"(?i)(application[ _\\*?a-z]*/buddy\b|buddy\.app|/\.claude/settings[^/]*\.json|\.claude\.json|"# + NSRegularExpression.escapedPattern(for: Config.bundleID) + ")"
        if tool == "Bash" {
            // Reading them is fine; anything else that names them asks.
            let looking = command.range(of: #"^\s*(ls|cat|head|tail|wc|stat|file)\b[^;&|>`$]*$"#, options: .regularExpression) != nil
            return !looking && command.range(of: sensitive, options: .regularExpression) != nil
        }
        guard ["Write", "Edit", "MultiEdit", "NotebookEdit"].contains(tool), let path else { return false }
        let full = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        return full.range(of: sensitive, options: .regularExpression) != nil
    }

    /// Changing files in one of the user's protected code folders (`Permissions.protectedFolders`).
    /// File tools are checked by path. For commands, any that names a protected folder (or `cd`s into
    /// one) and writes anything (sed -i, redirection, mv, cp, rm, tee, patch, an editor…) counts.
    var touchesProtectedCode: Bool {
        let folders = Permissions.protectedFolders.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }
        if ["Write", "Edit", "MultiEdit", "NotebookEdit"].contains(tool), let path {
            let full = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
            return folders.contains { full == $0 || full.hasPrefix($0 + "/") }
        }
        guard tool == "Bash" else { return false }
        let home = NSHomeDirectory()
        // Absolute, ~ and $HOME forms, plus the path relative to home when it has a slash ("code/cf"; a bare "cf" is too common).
        let names = folders.flatMap { folder -> [String] in
            let relative = folder.hasPrefix(home + "/") ? String(folder.dropFirst(home.count + 1)) : ""
            return [folder, folder.replacingOccurrences(of: home, with: "~"), folder.replacingOccurrences(of: home, with: "$HOME")]
                + (relative.contains("/") ? [relative] : [])
        }
        let lower = command.lowercased()
        guard names.contains(where: { lower.contains($0.lowercased()) }) else { return false }
        let writes = #"(\bsed\s+(-[a-z]*\s+)*-i|\bperl\s+-[a-z]*i|>|\btee\b|\bmv\b|\bcp\b|\brm\b|\btruncate\b|\bpatch\b|\bdd\b|\b(n?vim?|ed|ex|nano|emacs)\b|\bgit\s+(checkout|restore|reset|apply|stash)|open\([^)]*['"](w|a)|write_text|writeFile|\binstall\b|\bln\b|\btouch\b|\bchmod\b)"#
        // Writing a compiled program into /tmp (-o /tmp/…) or a redirect to /dev/null isn't a change to their code.
        let cleaned = command.replacingOccurrences(of: #"(2?>&?\s*/dev/null|-o\s+/(private/)?tmp/\S+|>\s*/(private/)?tmp/\S+|2>&1)"#, with: "", options: .regularExpression)
        return cleaned.range(of: writes, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The row on the Permissions screen this request falls under.
    var area: String? { Permissions.area(forTool: tool, input: input) }

    /// Deleting, force-pushing, sending to people, paying: asks every time, even after you've said yes in this task.
    var isDestructive: Bool {
        if touchesBuddySettings { return true }
        if tool == "Bash" {
            return command.range(of: #"(^|[\s;&|(])(rm|rmdir|sudo|shred|mkfs|dd|kill|killall|pkill|launchctl|diskutil|trash)\b|git\s+(push\s+.*(--force|-f\b)|reset\s+--hard|clean\s+-|branch\s+-D)|>\s*/dev/|curl[^|]*\|\s*(sh|bash|zsh)"#,
                                 options: .regularExpression) != nil
        }
        return action.range(of: #"\b(delete|remove|trash|send|forward|reply|share|pay|purchase|transfer|move)\b"#,
                            options: [.regularExpression, .caseInsensitive]) != nil
    }
}
