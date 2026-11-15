import CryptoKit
import Foundation
import Security

// MARK: - Permissions
//
// What Buddy may do without asking, kept in one place and one file
// (~/Library/Application Support/Buddy/permissions.json). Everything Buddy can do belongs to an
// *area* (`Permissions.areas`); each area has a level. The Settings window and `buddy permission`
// change levels; nothing else should write the file.
//
// Two rules sit above every level and can't be switched off (`Permissions.fixed`):
//   - destructive things (deleting, sending, paying, sudo, force-push…) ask every time;
//   - loosening a level, or adding or removing a feature, needs Touch ID.

/// How much Buddy asks before doing something in an area. Ordered from strictest to loosest.
enum Level: String, Codable, CaseIterable, Comparable {
    case off    // never does it
    case ask    // asks every time (Touch ID)
    case risky  // asks before changes and risky steps; one yes covers the rest of that request
    case allow  // never asks (destructive things still do)

    private var rank: Int { Level.allCases.firstIndex(of: self) ?? 0 }
    static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }

    /// The label on the settings control.
    var title: String {
        switch self {
        case .off: return "Off"
        case .ask: return "Always ask"
        case .risky: return "Ask when risky"
        case .allow: return "Never ask"
        }
    }
}

/// One thing Buddy can do, as a row on the Permissions screen.
struct Area {
    let id: String
    let group: String
    let title: String
    let detail: String
    /// The levels this area can be set to, strictest first.
    let levels: [Level]
    let fallback: Level
}

final class Permissions {
    static let shared = Permissions()

    /// Called on the main queue after a level changes.
    var onChange: (() -> Void)?

    // To add an area: add a row here, then make the code that does the thing check
    // `Permissions.shared.level("<id>")`. Buddy's own commands name their area in Commands.swift
    // (`BuddyCommand.area`); Claude Code's tools are mapped in `area(forTool:input:)` below.
    static let areas: [Area] = [
        Area(id: "screen.look", group: "Your screen", title: "Look at the screen",
             detail: "Screenshots and the list of buttons and fields in the app in front.",
             levels: [.off, .allow], fallback: .allow),
        Area(id: "screen.act", group: "Your screen", title: "Click, type and press keys",
             detail: "Everyday steps just run. Delete, Send, Pay and the like ask first.",
             levels: [.off, .ask, .risky], fallback: .risky),
        Area(id: "screen.open", group: "Your screen", title: "Open apps and links",
             detail: "Opening an app by name, or a web page.",
             levels: [.off, .ask, .allow], fallback: .allow),
        Area(id: "screen.draw", group: "Your screen", title: "Draw and point",
             detail: "Circles, arrows, notes and the blue cursor. Nothing is clicked.",
             levels: [.off, .allow], fallback: .allow),

        Area(id: "shell", group: "Your Mac", title: "Run commands",
             detail: "Anything in the terminal beyond looking (ls, cat, git status never ask).",
             levels: [.off, .ask, .risky, .allow], fallback: .risky),
        Area(id: "files.edit", group: "Your Mac", title: "Create and edit files",
             detail: "Writing or changing files anywhere on this Mac.",
             levels: [.off, .ask, .risky, .allow], fallback: .risky),
        Area(id: "web", group: "Your Mac", title: "Search the web",
             detail: "Web searches and reading pages.",
             levels: [.off, .ask, .allow], fallback: .allow),
        Area(id: "memory", group: "Your Mac", title: "Remember things",
             detail: "Saving how you do things to Claude's memory files.",
             levels: [.off, .ask, .allow], fallback: .allow),

        Area(id: "connector.obsidian", group: "Connectors", title: "Obsidian",
             detail: "Reading notes never asks. Changing them does.",
             levels: [.off, .ask, .risky], fallback: .risky),
        Area(id: "connector.gmail", group: "Connectors", title: "Gmail",
             detail: "Reading mail never asks. Drafts and labels do. Sending asks every time.",
             levels: [.off, .ask, .risky], fallback: .risky),
        Area(id: "connector.calendar", group: "Connectors", title: "Google Calendar",
             detail: "Reading events never asks. Creating and changing them does.",
             levels: [.off, .ask, .risky], fallback: .risky),
        Area(id: "connector.drive", group: "Connectors", title: "Google Drive",
             detail: "Searching and reading files never asks. Changing them does.",
             levels: [.off, .ask, .risky], fallback: .risky),
        Area(id: "connector.todoist", group: "Connectors", title: "Todoist",
             detail: "Reading tasks never asks. Adding and completing them does.",
             levels: [.off, .ask, .risky], fallback: .risky),
        Area(id: "connector.other", group: "Connectors", title: "Other connectors",
             detail: "Any other MCP server the claude CLI has. Asks before each use.",
             levels: [.off, .ask, .risky], fallback: .risky),
    ]

    /// Folders of the user's own code that Buddy never changes (Claude's file edits and commands that
    /// write there are refused outright, with no card to approve). Reading and compiling are fine; the
    /// cf-start feature still creates new solution files, since it doesn't go through Claude's tools.
    static let protectedFolders = Config.protectedFolders

    /// Rules no setting changes, shown locked at the bottom of the Permissions screen.
    static let fixed: [(title: String, detail: String, level: String)] = [
        ("Change your competitive-programming code", "Files in " + protectedFolders.joined(separator: " and ") + ": reading and compiling only.", "Never"),
        ("Read files and notes", "Looking never changes anything, so it never asks.", "Never asks"),
        ("Delete, send, pay, sudo, force-push", "Hard to undo, so one yes never covers the next one.", "Asks every time"),
        ("Change Buddy's features and permissions", "Loosening a permission, or adding or removing a feature.", "Touch ID"),
    ]

    private var levels: [String: Level] = [:]
    /// Features you approved, by folder name: the hash of their folder at that moment.
    private var pins: [String: String] = [:]
    private var loadedAt: Date?
    /// The file was changed, replaced or deleted outside Buddy. Until you restore or set the levels again,
    /// every area is at its strictest ("Always ask", or Off where there's no asking) and features ask.
    private(set) var tampered = false

    private static let file: URL = Buddy.supportDir.appendingPathComponent("permissions.json")

    // The file is signed with a key only Buddy can read (the Keychain), and carries a save counter that
    // must match the one in the Keychain, so neither an edit nor putting back an older copy loosens anything.
    private struct Body: Codable { var generation: Int; var levels: [String: Level]; var pins: [String: String]? }
    private struct Stored: Codable { var generation: Int?; var levels: [String: Level]; var pins: [String: String]?; var signature: String? }

    private init() { load() }

    /// Picks up the file again when it changes on disk.
    private func load() {
        let modified = (try? FileManager.default.attributesOfItem(atPath: Self.file.path))?[.modificationDate] as? Date
        guard modified != loadedAt || loadedAt == nil else { return }
        loadedAt = modified
        let generation = SettingsKey.generation
        guard let data = try? Data(contentsOf: Self.file), let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            levels = [:]; pins = [:]
            // Never saved (a fresh install) is fine; saved before and now missing or unreadable is not.
            tampered = generation > 0
            return
        }
        let body = Body(generation: stored.generation ?? 0, levels: stored.levels, pins: stored.pins)
        let fresh = generation == 0 && stored.signature == nil && stored.levels.isEmpty && (stored.pins ?? [:]).isEmpty
        let genuine = stored.signature.map { SettingsKey.verify(Self.encode(body), $0) } == true && body.generation == generation
        if fresh || genuine {
            levels = stored.levels
            pins = stored.pins ?? [:]
            tampered = false
        } else {
            levels = [:]
            pins = [:]
            tampered = true
        }
    }

    private static func encode(_ body: Body) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(body)) ?? Data()
    }

    /// The strictest level an area offers short of nothing at all: "Always ask", else Off.
    private static func strictest(_ area: Area) -> Level { area.levels.contains(.ask) ? .ask : area.levels.first ?? .off }

    /// The level of an area, or of a feature ("feature.<id>", which falls back to `fallback`).
    func level(_ id: String, fallback: Level? = nil) -> Level {
        load()
        if let area = Self.areas.first(where: { $0.id == id }) {
            if tampered { return Self.strictest(area) }
            // A level the area doesn't offer (a stale file) counts as its default.
            return levels[id].flatMap { area.levels.contains($0) ? $0 : nil } ?? area.fallback
        }
        if tampered { return .ask }
        return levels[id] ?? fallback ?? .risky
    }

    /// Whether `level` is one the area (or a feature) can take.
    func accepts(_ id: String, _ level: Level) -> Bool {
        if id.hasPrefix("feature.") { return Feature.levels.contains(level) }
        return Self.areas.first { $0.id == id }?.levels.contains(level) ?? false
    }

    /// Saves a level. Callers decide first whether the change needs Touch ID (`loosens`).
    func set(_ id: String, _ level: Level) {
        load()
        // After tampering, the strict levels in force become the saved ones, so tightening one row
        // (which needs no Touch ID) can't bring the looser defaults back for the others.
        if tampered {
            levels = Dictionary(uniqueKeysWithValues: Self.areas.map { ($0.id, Self.strictest($0)) })
            for feature in FeatureStore.all() { levels[feature.permissionID] = .ask }
            pins = [:]
        }
        levels[id] = level
        save()
    }

    /// Back to the defaults, with nothing approved. Only after Touch ID (Settings' banner).
    func restoreDefaults() {
        load()
        levels = [:]
        pins = [:]
        save()
    }

    func forget(_ id: String) {
        load()
        guard !tampered, levels.removeValue(forKey: id) != nil else { return }
        save()
    }

    /// Asking less than before: needs your fingerprint.
    func loosens(_ id: String, to level: Level, fallback: Level? = nil) -> Bool {
        level > self.level(id, fallback: fallback)
    }

    // MARK: Approved features

    func pin(_ featureID: String) -> String? { load(); return tampered ? nil : pins[featureID] }

    /// Records a feature's current files as approved. Only after Touch ID.
    func approve(_ featureID: String, hash: String) {
        load()
        if tampered { set("feature.\(featureID)", .ask) } // keeps the strict levels; see set(_:_:)
        pins[featureID] = hash
        save()
    }

    func unpin(_ featureID: String) {
        load()
        guard pins.removeValue(forKey: featureID) != nil else { return }
        save()
    }

    private func save() {
        // Bump the counter in the Keychain first: an older copy of the file stops matching.
        guard let generation = SettingsKey.bumpGeneration() else { return }
        let body = Body(generation: generation, levels: levels, pins: pins.isEmpty ? nil : pins)
        let stored = Stored(generation: generation, levels: levels, pins: body.pins, signature: SettingsKey.sign(Self.encode(body)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        try? data.write(to: Self.file, options: .atomic)
        loadedAt = (try? FileManager.default.attributesOfItem(atPath: Self.file.path))?[.modificationDate] as? Date
        tampered = false
        DispatchQueue.main.async { self.onChange?() }
    }

    // MARK: Claude Code's tools

    /// The area a Claude Code tool (or an allow-list pattern for one) belongs to; nil for tools that
    /// are part of how Buddy itself works and always run (its own CLI, tool search, to-do notes).
    static func area(forTool tool: String, input: [String: Any] = [:]) -> String? {
        let name = tool.components(separatedBy: "(").first ?? tool
        if tool.hasPrefix("Bash(buddy:") || ["ToolSearch", "TodoWrite"].contains(name) { return nil }
        if name.hasPrefix("mcp__") {
            let server = name.lowercased()
            for key in ["obsidian", "gmail", "calendar", "drive", "todoist"] where server.contains(key) { return "connector.\(key)" }
            return "connector.other"
        }
        switch name {
        case "Read", "Glob", "Grep": return nil // looking is always allowed
        case "Bash": return tool == "Bash" ? "shell" : nil // the read-only patterns (ls, cat, git status…) only look
        case "WebSearch", "WebFetch": return "web"
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            let path = (input["file_path"] ?? input["path"] ?? input["notebook_path"]) as? String ?? tool
            return path.contains("/.claude/projects/") && path.contains("/memory/") ? "memory" : "files.edit"
        default: return "shell" // an unknown tool is treated like a command
        }
    }

    /// The tools Claude Code may use without a permission request: the read-only list, minus anything
    /// whose area is set to ask every time or is off (those then arrive as requests and are asked or denied).
    var allowedTools: [String] {
        ToolPermission.readOnly.filter { pattern in
            guard let area = Self.area(forTool: pattern) else { return true }
            return level(area) >= .risky
        }
    }

    /// Changes whenever the allow-list would: Claude Code must be restarted to pick it up.
    var signature: String { allowedTools.joined(separator: ",") }
}

/// Where Buddy keeps its own files.
enum Buddy {
    static let supportDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Buddy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

/// The key that signs permissions.json, and the file's save counter, in the login Keychain. Made on
/// first use. The items' access lists trust only Buddy itself, so another process (a shell command,
/// `security find-generic-password`) gets the system's "allow access?" prompt instead. Lookups are
/// limited to the login keychain, so a keychain added to the search list can't supply its own key.
enum SettingsKey {
    private static let service = Config.bundleID + ".settings"
    private static var cachedKey: SymmetricKey?

    /// `--demo`, `--scene` and `--canvas-test` copies never touch the Keychain: a rebuilt or second copy
    /// of Buddy would ask for the login password, and they have no settings to save. Without the key,
    /// `save()` stops before writing, so they can't change the real settings either.
    static let staging = ["--demo", "--scene", "--canvas-test"].contains { CommandLine.arguments.contains($0) }

    private static let login: SecKeychain? = {
        if staging { return nil }
        var keychain: SecKeychain?
        let path = NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
        return SecKeychainOpen(path, &keychain) == errSecSuccess ? keychain : nil
    }()

    private static func query(_ account: String) -> [String: Any]? {
        guard let login else { return nil }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecMatchSearchList as String: [login]]
    }

    private static func read(_ account: String) -> Data? {
        guard var q = query(account) else { return nil }
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess ? item as? Data : nil
    }

    private static func write(_ account: String, _ data: Data, label: String) -> Bool {
        guard let q = query(account), let login else { return false }
        if read(account) != nil {
            return SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess
        }
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecAttrLabel as String: label,
                                  kSecValueData as String: data, kSecUseKeychain as String: login]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    // One Keychain item holds both the key (32 bytes) and the save counter after it, so a rebuilt Buddy
    // (which macOS treats as a new app) asks for Keychain access once, not once per item.
    private static var cached: (key: SymmetricKey, generation: Int)?

    private static func item() -> (key: SymmetricKey, generation: Int)? {
        if let cached { return cached }
        if let data = read("signing"), data.count >= 32 {
            let generation = Int(String(decoding: data.dropFirst(32), as: UTF8.self)) ?? 0
            cached = (SymmetricKey(data: data.prefix(32)), generation)
            return cached
        }
        let fresh = SymmetricKey(size: .bits256)
        guard write("signing", fresh.withUnsafeBytes { Data($0) }, label: "Buddy settings key") else { return nil }
        cached = (fresh, 0)
        return cached
    }

    private static func key() -> SymmetricKey? { item()?.key }

    /// How many times Buddy has saved its settings (0: never).
    static var generation: Int { item()?.generation ?? 0 }

    /// The next save's number, already stored; nil if the Keychain can't be written.
    static func bumpGeneration() -> Int? {
        guard let current = item() else { return nil }
        let next = current.generation + 1
        let data = current.key.withUnsafeBytes { Data($0) } + Data(String(next).utf8)
        guard write("signing", data, label: "Buddy settings key") else { return nil }
        cached = (current.key, next)
        return next
    }

    static func sign(_ data: Data) -> String? {
        guard let key = key() else { return nil }
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: key)).base64EncodedString()
    }

    static func verify(_ data: Data, _ signature: String) -> Bool {
        guard let key = key(), let mac = Data(base64Encoded: signature) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: data, using: key)
    }
}
