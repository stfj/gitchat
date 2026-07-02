import Foundation

/// Local persistence: JSON files under ~/Library/Application Support/gitchat.
/// Everything here is a rebuildable cache of GitHub state plus per-chat flags
/// (pinned/ignored/unread), so a schema bump just re-syncs.
@MainActor
final class Store {
    static let schemaVersion = 1

    nonisolated static var baseDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gitchat", isDirectory: true)
    }
    nonisolated static var transcriptsDir: URL {
        baseDir.appendingPathComponent("transcripts", isDirectory: true)
    }
    nonisolated static var translationsDir: URL {
        baseDir.appendingPathComponent("translations", isDirectory: true)
    }

    private var chatsURL: URL { Self.baseDir.appendingPathComponent("chats.json") }
    private var reposURL: URL { Self.baseDir.appendingPathComponent("repos.json") }
    private var settingsURL: URL { Self.baseDir.appendingPathComponent("settings.json") }
    private var metaURL: URL { Self.baseDir.appendingPathComponent("meta.json") }

    nonisolated private static let enc: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    nonisolated private static let dec: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// chatID → per-message search entries (full text of the conversation).
    private(set) var messageIndex: [String: [IndexedMessage]] = [:]

    init() {
        try? FileManager.default.createDirectory(at: Self.transcriptsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.translationsDir, withIntermediateDirectories: true)
    }

    private struct ChatsFile: Codable {
        var version: Int
        var chats: [Chat]
    }

    // MARK: chats

    func loadChats() -> [String: Chat] {
        guard let data = try? Data(contentsOf: chatsURL),
              let file = try? Self.dec.decode(ChatsFile.self, from: data),
              file.version == Self.schemaVersion else { return [:] }
        var out: [String: Chat] = [:]
        for c in file.chats { out[c.id] = c }
        for c in file.chats where messageIndex[c.id] == nil {
            messageIndex[c.id] = fallbackEntries(for: c)
        }
        return out
    }

    func saveChats(_ chats: [String: Chat]) {
        let file = ChatsFile(version: Self.schemaVersion, chats: Array(chats.values))
        if let data = try? Self.enc.encode(file) {
            try? data.write(to: chatsURL, options: [.atomic])
        }
    }

    // MARK: repos / settings / meta

    func loadRepos() -> [RepoInfo] {
        guard let data = try? Data(contentsOf: reposURL) else { return [] }
        return (try? Self.dec.decode([RepoInfo].self, from: data)) ?? []
    }

    func saveRepos(_ repos: [RepoInfo]) {
        if let data = try? Self.enc.encode(repos) {
            try? data.write(to: reposURL, options: [.atomic])
        }
    }

    func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL) else { return AppSettings() }
        return (try? Self.dec.decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    func saveSettings(_ s: AppSettings) {
        if let data = try? Self.enc.encode(s) {
            try? data.write(to: settingsURL, options: [.atomic])
        }
    }

    func loadMeta() -> StoreMeta {
        guard let data = try? Data(contentsOf: metaURL) else { return StoreMeta() }
        return (try? Self.dec.decode(StoreMeta.self, from: data)) ?? StoreMeta()
    }

    func saveMeta(_ m: StoreMeta) {
        if let data = try? Self.enc.encode(m) {
            try? data.write(to: metaURL, options: [.atomic])
        }
    }

    // MARK: transcripts

    nonisolated private static func transcriptURL(fileKey: String) -> URL {
        transcriptsDir.appendingPathComponent(fileKey + ".json")
    }

    func loadTranscript(_ chat: Chat) -> [Message]? {
        Self.readTranscript(fileKey: chat.fileKey)
    }

    nonisolated static func readTranscript(fileKey: String) -> [Message]? {
        guard let data = try? Data(contentsOf: transcriptURL(fileKey: fileKey)) else { return nil }
        return try? dec.decode([Message].self, from: data)
    }

    func saveTranscript(_ chat: Chat, _ messages: [Message]) {
        if let data = try? Self.enc.encode(messages) {
            try? data.write(to: Self.transcriptURL(fileKey: chat.fileKey), options: [.atomic])
        }
        messageIndex[chat.id] = Self.entries(from: messages)
    }

    // MARK: PR translations

    func hasTranslation(_ chat: Chat) -> Bool {
        FileManager.default.fileExists(
            atPath: Self.translationsDir.appendingPathComponent(chat.fileKey + ".json").path)
    }

    func loadTranslation(_ chat: Chat) -> StoredTranslation? {
        let url = Self.translationsDir.appendingPathComponent(chat.fileKey + ".json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.dec.decode(StoredTranslation.self, from: data)
    }

    func saveTranslation(_ chat: Chat, _ translation: StoredTranslation) {
        let url = Self.translationsDir.appendingPathComponent(chat.fileKey + ".json")
        if let data = try? Self.enc.encode(translation) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    // MARK: search index

    nonisolated private static func entries(from messages: [Message]) -> [IndexedMessage] {
        messages.map {
            IndexedMessage(id: $0.id, author: $0.author, text: $0.body, createdAt: $0.createdAt)
        }
    }

    /// Until the full transcript lands, the last-message snippet stands in so
    /// the chat is still findable. Jumps to it just open the chat normally.
    private func fallbackEntries(for chat: Chat) -> [IndexedMessage] {
        guard !chat.lastMessageSnippet.isEmpty else { return [] }
        return [IndexedMessage(id: "fallback",
                               author: chat.lastMessageAuthor ?? chat.author,
                               text: chat.lastMessageSnippet,
                               createdAt: chat.lastMessageAt)]
    }

    func indexChat(_ chat: Chat, body: String?) {
        var entries: [IndexedMessage] = []
        if let body, !body.isEmpty {
            entries.append(IndexedMessage(id: "body", author: chat.author, text: body, createdAt: chat.createdAt))
        }
        // The snippet duplicates the body for comment-less chats; only add it
        // when it points at a different (newer) message.
        if chat.commentCount > 0 || entries.isEmpty {
            entries.append(contentsOf: fallbackEntries(for: chat))
        }
        messageIndex[chat.id] = entries
    }

    func appendIndex(chatID: String, messages: [Message]) {
        guard !messages.isEmpty else { return }
        var list = messageIndex[chatID] ?? []
        let known = Set(list.map(\.id))
        list += Self.entries(from: messages.filter { !known.contains($0.id) })
        messageIndex[chatID] = list
    }

    /// Fold every on-disk transcript into the search index (runs shortly after launch).
    func buildSearchIndex(chats: [String: Chat]) async {
        let items = chats.values.map { (id: $0.id, fileKey: $0.fileKey) }
        for item in items {
            let messages = await Task.detached(priority: .utility) {
                Store.readTranscript(fileKey: item.fileKey)
            }.value
            if let messages {
                messageIndex[item.id] = Self.entries(from: messages)
            }
        }
    }

    func wipe() {
        try? FileManager.default.removeItem(at: Self.baseDir)
        try? FileManager.default.createDirectory(at: Self.transcriptsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.translationsDir, withIntermediateDirectories: true)
        messageIndex = [:]
    }
}
