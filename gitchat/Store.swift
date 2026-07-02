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

    /// chatID → searchable text (title, repo, participants, message bodies).
    private(set) var searchBlobs: [String: String] = [:]

    init() {
        try? FileManager.default.createDirectory(at: Self.transcriptsDir, withIntermediateDirectories: true)
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
        for c in file.chats where searchBlobs[c.id] == nil {
            searchBlobs[c.id] = baseBlob(for: c)
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
        searchBlobs[chat.id] = transcriptBlob(for: chat, messages: messages)
    }

    // MARK: search index

    private func baseBlob(for chat: Chat) -> String {
        [chat.title, chat.repoFullName, "#\(chat.number)", chat.author.login, chat.lastMessageSnippet]
            .joined(separator: "\n")
    }

    private func transcriptBlob(for chat: Chat, messages: [Message]) -> String {
        var parts = [chat.title, chat.repoFullName, "#\(chat.number)"]
        parts += messages.map { "\($0.author.login): \($0.body)" }
        return parts.joined(separator: "\n")
    }

    func indexChat(_ chat: Chat, body: String?) {
        var blob = baseBlob(for: chat)
        if let body, !body.isEmpty { blob += "\n" + chat.author.login + ": " + body }
        searchBlobs[chat.id] = blob
    }

    func appendIndex(chatID: String, messages: [Message]) {
        guard !messages.isEmpty else { return }
        var blob = searchBlobs[chatID] ?? ""
        blob += "\n" + messages.map { "\($0.author.login): \($0.body)" }.joined(separator: "\n")
        searchBlobs[chatID] = blob
    }

    /// Fold every on-disk transcript into the search index (runs shortly after launch).
    func buildSearchIndex(chats: [String: Chat]) async {
        let items = chats.values.map { (id: $0.id, fileKey: $0.fileKey, chat: $0) }
        for item in items {
            let messages = await Task.detached(priority: .utility) {
                Store.readTranscript(fileKey: item.fileKey)
            }.value
            if let messages {
                searchBlobs[item.id] = transcriptBlob(for: item.chat, messages: messages)
            }
        }
    }

    func wipe() {
        try? FileManager.default.removeItem(at: Self.baseDir)
        try? FileManager.default.createDirectory(at: Self.transcriptsDir, withIntermediateDirectories: true)
        searchBlobs = [:]
    }
}
