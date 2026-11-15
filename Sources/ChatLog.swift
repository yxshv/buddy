import Foundation

/// Every conversation with Buddy, kept on disk for the chats window
/// (~/Library/Application Support/Buddy/chats.json).
final class ChatLog {
    struct Message: Codable {
        var role: String // "user" or "buddy"
        var text: String
        var board: String?
        var cards: [ResultCard]?
        var at: Double // ms since 1970, for the page's Date
    }

    struct Chat: Codable {
        var id: String
        var started: Double
        var messages: [Message]
    }

    /// Called whenever something is added, so an open chats window can update.
    var onChange: (() -> Void)?
    private(set) var chats: [Chat] = [] // oldest first

    private var forceNew = false
    private static let gap: Double = 30 * 60 * 1000 // a pause this long starts a new chat
    private static let limit = 300

    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Buddy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("chats.json")
    }()

    init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Chat].self, from: data) {
            chats = saved
        }
    }

    var currentID: String? { chats.last?.id }

    /// The next message starts a new chat ("New conversation" in the menu).
    func startNew() { forceNew = true }

    func add(_ role: String, text: String, board: String? = nil, cards: [ResultCard] = []) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let board = board.flatMap { $0.isEmpty ? nil : $0 }
        guard !text.isEmpty || board != nil || !cards.isEmpty else { return }
        let now = Date().timeIntervalSince1970 * 1000
        let message = Message(role: role, text: text, board: board, cards: cards.isEmpty ? nil : cards, at: now)
        if !forceNew, var last = chats.last, let lastAt = last.messages.last?.at, now - lastAt < Self.gap {
            last.messages.append(message)
            chats[chats.count - 1] = last
        } else {
            chats.append(Chat(id: UUID().uuidString, started: now, messages: [message]))
            if chats.count > Self.limit { chats.removeFirst(chats.count - Self.limit) }
        }
        forceNew = false
        save()
        onChange?()
    }

    /// Newest first, as JSON for the chats page.
    func json() -> String {
        guard let data = try? JSONEncoder().encode(Array(chats.reversed())) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private func save() {
        let snapshot = chats
        let file = file
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
        }
    }
}
