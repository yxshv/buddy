import Foundation

/// `buddy obsidian publish`: tags a note `public` and runs the Astro publisher, which copies every
/// public note into the site and pushes it (for example to Vercel). The project is `Config.publisherDir`; the vault path comes from the
/// publisher's own obsidian-public.config.ts.
enum ObsidianPublisher {
    static let project = URL(fileURLWithPath: Config.publisherDir)

    static var vault: URL? {
        guard let config = try? String(contentsOf: project.appendingPathComponent("obsidian-public.config.ts"), encoding: .utf8),
              let range = config.range(of: #"vaultPath:\s*['"]([^'"]+)['"]"#, options: .regularExpression) else { return nil }
        let line = String(config[range])
        guard let start = line.firstIndex(where: { $0 == "'" || $0 == "\"" }) else { return nil }
        return URL(fileURLWithPath: String(line[line.index(after: start)..<line.index(before: line.endIndex)]))
    }

    /// A path, a path inside the vault, or a note's name (exact first, then partial).
    static func findNote(_ query: String) -> URL? {
        let fm = FileManager.default
        let expanded = (query as NSString).expandingTildeInPath
        if expanded.hasPrefix("/"), fm.fileExists(atPath: expanded) { return URL(fileURLWithPath: expanded) }
        guard let vault else { return nil }
        for candidate in [query, query + ".md"] where fm.fileExists(atPath: vault.appendingPathComponent(candidate).path) {
            return vault.appendingPathComponent(candidate)
        }
        let want = query.lowercased().replacingOccurrences(of: ".md", with: "")
        var partial: URL?
        let walker = fm.enumerator(at: vault, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let file = walker?.nextObject() as? URL {
            guard file.pathExtension == "md" else { continue }
            let name = file.deletingPathExtension().lastPathComponent.lowercased()
            if name == want { return file }
            if partial == nil, name.contains(want) { partial = file }
        }
        return partial
    }

    /// Adds `public` to the note's frontmatter tags, keeping its other tags. Returns false if it already had it.
    static func markPublic(_ note: URL) throws -> Bool {
        var text = try String(contentsOf: note, encoding: .utf8)
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        guard text.hasPrefix("---" + newline),
              let close = text.range(of: newline + "---", range: text.index(text.startIndex, offsetBy: 3 + newline.count)..<text.endIndex) else {
            text = "---\ntags:\n  - public\n---\n\n" + text
            try text.write(to: note, atomically: true, encoding: .utf8)
            return true
        }
        let headerStart = text.index(text.startIndex, offsetBy: 3 + newline.count)
        var lines = text[headerStart..<close.lowerBound].components(separatedBy: newline)
        if let i = lines.firstIndex(where: { $0.hasPrefix("tags:") }) {
            let rest = lines[i].dropFirst(5).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                // A YAML list on the following lines.
                var j = i + 1
                var indent = "  "
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("-") {
                    let item = lines[j].trimmingCharacters(in: .whitespaces).dropFirst().trimmingCharacters(in: .whitespaces)
                    if item.lowercased() == "public" { return false }
                    indent = String(lines[j].prefix { $0 == " " })
                    j += 1
                }
                lines.insert("\(indent)- public", at: j)
            } else {
                let items = rest.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if items.contains(where: { $0.lowercased() == "public" }) { return false }
                lines[i] = "tags: [" + (items + ["public"]).joined(separator: ", ") + "]"
            }
        } else {
            lines += ["tags:", "  - public"]
        }
        text = String(text[..<headerStart]) + lines.joined(separator: newline) + String(text[close.lowerBound...])
        try text.write(to: note, atomically: true, encoding: .utf8)
        return true
    }

    /// Runs git in the publisher project; returns its exit status and output.
    @discardableResult
    private static func git(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = project
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return (-1, "") }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A published note's title (its frontmatter `title:`).
    private static func title(of published: String) -> String? {
        guard let range = published.range(of: #"(?m)^title:\s*(.+)$"#, options: .regularExpression) else { return nil }
        return published[range].dropFirst(6).trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
    }

    /// The site's address, from the publisher's output (it prints each note's URL), else the
    /// publisher's own default SITE_URL.
    private static func siteURL(from output: String) -> String {
        if let range = output.range(of: #"https?://\S+?/notes/"#, options: .regularExpression) {
            return String(output[range].dropLast("notes/".count))
        }
        if let script = try? String(contentsOf: project.appendingPathComponent("scripts/publish-public.ts"), encoding: .utf8),
           let range = script.range(of: #"SITE_URL \|\| '[^']+'"#, options: .regularExpression) {
            let url = script[range].split(separator: "'")[1]
            return url.hasSuffix("/") ? String(url) : url + "/"
        }
        guard let site = Config.siteURL else { return "" }
        return site.hasSuffix("/") ? site : site + "/"
    }

    /// Marks `note` public (if given), then runs `bun run publish:push` in the publisher project.
    /// `done` gets the text for Claude and a card for each note that was published, updated or removed.
    static func publish(making note: URL?, done: @escaping (String, [ResultCard]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var report: [String] = []
            if let note {
                do {
                    report.append(try markPublic(note) ? "Tagged \(note.lastPathComponent) public." : "\(note.lastPathComponent) was already public.")
                } catch {
                    done("error: couldn't tag \(note.lastPathComponent) public: \(error.localizedDescription)", [])
                    return
                }
            }
            // What's live: the commit GitHub had before this publish. Cards compare against it, so a
            // retry after a failed push still shows everything that went live.
            let live = git(["rev-parse", "@{u}"]).output
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", "bun run publish:push"]
            p.currentDirectoryURL = project
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = ["\(home)/.bun/bin", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch {
                done("error: couldn't run the publisher in \(project.path): \(error.localizedDescription)", [])
                return
            }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                let tail = output.split(separator: "\n").suffix(12).joined(separator: "\n")
                done("error: the publisher failed (exit \(p.terminationStatus)). Run `buddy obsidian publish` again to retry; never push by hand.\n"
                     + (report + [tail]).joined(separator: "\n"), [])
                return
            }
            // The publisher only pushes when it made a new commit; a commit left over from a failed push goes now.
            if git(["rev-list", "--count", "@{u}..HEAD"]).output != "0" {
                let push = git(["push"])
                guard push.status == 0 else {
                    done("error: GitHub refused the push. Run `buddy obsidian publish` again to retry; never push by hand.\n" + push.output, [])
                    return
                }
            }

            // What changed on the site since the last live commit: new, edited and removed notes.
            let site = siteURL(from: output)
            var cards: [ResultCard] = []
            let changes = live.isEmpty ? "" : git(["diff", "--name-status", live, "HEAD", "--", "src/content/notes"]).output
            for line in changes.split(separator: "\n") {
                let parts = line.split(separator: "\t").map(String.init)
                guard parts.count >= 2, parts.last!.hasSuffix(".md") else { continue }
                let path = parts.last!
                let slug = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                switch parts[0].prefix(1) {
                case "A", "M", "R":
                    let text = (try? String(contentsOf: project.appendingPathComponent(path), encoding: .utf8)) ?? ""
                    cards.append(ResultCard(kind: "note", title: title(of: text) ?? slug,
                                            subtitle: parts[0].hasPrefix("M") ? "Updated" : "Published", url: site + "notes/\(slug)/"))
                case "D":
                    let text = git(["show", "\(live):\(path)"]).output
                    cards.append(ResultCard(kind: "note", title: title(of: text) ?? slug, subtitle: "Removed from the site"))
                default:
                    break
                }
            }
            cards.sort { ($0.subtitle == "Removed from the site" ? 1 : 0, $0.title) < ($1.subtitle == "Removed from the site" ? 1 : 0, $1.title) }
            let summary = cards.isEmpty
                ? "ok: nothing changed; the site already has every public note. Say so in a few words."
                : "ok: published. Cards for each changed note are already on screen, so just say \"Done.\"\n" +
                  cards.map { "- \($0.subtitle ?? ""): \($0.title) \($0.url ?? "")" }.joined(separator: "\n")
            done(([summary] + report).joined(separator: "\n"), cards)
        }
    }
}
