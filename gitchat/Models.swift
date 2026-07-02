import SwiftUI

// MARK: - Core value types

struct GHUserRef: Codable, Hashable {
    var login: String
    var avatarURL: String?
}

struct LabelTag: Codable, Hashable {
    var name: String
    var colorHex: String
}

struct Attachment: Codable, Hashable {
    var url: String
    var alt: String?
    var isImage: Bool
}

/// One issue == one chat.
struct Chat: Codable, Identifiable, Hashable {
    var id: String                  // "owner/repo#123"
    var repoFullName: String
    var number: Int
    var title: String
    var isPullRequest: Bool
    var state: String               // "open" | "closed"
    var author: GHUserRef
    var assignees: [GHUserRef]
    var labels: [LabelTag]
    var commentCount: Int
    var htmlURL: String
    var createdAt: Date
    var updatedAt: Date
    var lastMessageAt: Date
    var lastMessageSnippet: String
    var lastMessageAuthor: GHUserRef?
    var unreadCount: Int
    var pinned: Bool
    var ignored: Bool
    var transcriptSyncedAt: Date?

    static func key(repo: String, number: Int) -> String { "\(repo)#\(number)" }

    /// Filesystem-safe name for the transcript file.
    var fileKey: String {
        id.replacingOccurrences(of: "/", with: "__").replacingOccurrences(of: "#", with: "--")
    }
    var isOpen: Bool { state == "open" }
}

struct Message: Codable, Identifiable, Hashable {
    var id: String                  // "body", a comment id, or "local-<uuid>"
    var commentID: Int?
    var author: GHUserRef
    var body: String
    var createdAt: Date
    var updatedAt: Date?
    var htmlURL: String?
    var attachments: [Attachment]
    var pending: Bool
    var failed: Bool
}

struct RepoInfo: Codable, Hashable, Identifiable {
    var fullName: String
    var isPrivate: Bool
    var hasIssues: Bool
    var archived: Bool
    var canPush: Bool
    var pushedAt: Date?
    var lastIssueSync: Date?
    var ownerAvatarURL: String?
    var id: String { fullName }
}

/// One searchable message (or stand-in) in the per-chat search index.
struct IndexedMessage {
    var id: String
    var author: GHUserRef
    var text: String
    var createdAt: Date
}

/// A "scroll to this message" request; token makes repeat jumps distinct.
struct MessageJump: Equatable {
    var chatID: String
    var messageID: String
    var token = UUID()
}

/// A full-text search result pointing at one message.
struct MessageHit: Identifiable {
    var chatID: String
    var messageID: String
    var chatTitle: String
    var repoLine: String
    var author: GHUserRef
    var snippet: String
    var createdAt: Date
    var id: String { chatID + "|" + messageID }
}

enum ChatFilter: String, CaseIterable, Identifiable {
    case all = "All Chats"
    case unread = "Unread"
    case ignored = "Ignored"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: "bubble.left.and.bubble.right"
        case .unread: "app.badge"
        case .ignored: "bell.slash"
        }
    }
}

// MARK: - Settings & meta (lenient decoding so upgrades keep user data)

struct AppSettings: Codable {
    var pollSeconds: Double = 60
    var historyDays: Int = 30
    var includePullRequests: Bool = false
    var showClosed: Bool = false
    var assetsRepoName: String = "gitchat-assets"
    var apiBase: String = "https://api.github.com"
    var notificationsEnabled: Bool = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pollSeconds = try c.decodeIfPresent(Double.self, forKey: .pollSeconds) ?? 60
        historyDays = try c.decodeIfPresent(Int.self, forKey: .historyDays) ?? 30
        includePullRequests = try c.decodeIfPresent(Bool.self, forKey: .includePullRequests) ?? false
        showClosed = try c.decodeIfPresent(Bool.self, forKey: .showClosed) ?? false
        assetsRepoName = try c.decodeIfPresent(String.self, forKey: .assetsRepoName) ?? "gitchat-assets"
        apiBase = try c.decodeIfPresent(String.self, forKey: .apiBase) ?? "https://api.github.com"
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
    }
}

struct StoreMeta: Codable {
    var lastFirehose: Date? = nil
    var initialSyncDone: Bool = false
    var cyclesRun: Int = 0

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastFirehose = try c.decodeIfPresent(Date.self, forKey: .lastFirehose)
        initialSyncDone = try c.decodeIfPresent(Bool.self, forKey: .initialSyncDone) ?? false
        cyclesRun = try c.decodeIfPresent(Int.self, forKey: .cyclesRun) ?? 0
    }
}

// MARK: - Helpers

func gclog(_ s: String) {
    print("[gitchat] \(s)")
}

/// Markdown → single-line human snippet for chat rows and notifications.
func plainSnippet(_ markdown: String, limit: Int = 240) -> String {
    var s = markdown
    // Issue templates open bodies with a "Description" heading — boilerplate
    // that wastes the preview. Drop it when it's a line of its own.
    s = s.replacingOccurrences(
        of: "^\\s*(?:#{1,6}\\s*|\\*\\*)?(?:Description|Describe the bug)(?:\\*\\*)?\\s*:?\\s*(\\r?\\n)+",
        with: "",
        options: [.regularExpression, .caseInsensitive]
    )
    s = s.replacingOccurrences(of: "```[^\\n]*", with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "📷", options: .regularExpression)
    s = s.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
    s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: "[#>*_`~|]", with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.count > limit { s = String(s.prefix(limit)) + "…" }
    return s
}

/// Display-time preview cleanup: drops a leading "Description" word left over
/// from template headings (covers snippets cached before the rule above, and
/// headings flattened without a newline).
func previewSnippet(_ snippet: String) -> String {
    let cleaned = snippet.replacingOccurrences(
        of: "^Description[:\\s]+",
        with: "",
        options: [.regularExpression, .caseInsensitive]
    )
    return cleaned.isEmpty ? snippet : cleaned
}

extension Date {
    /// Messages-style sidebar timestamp: time today, "Yesterday", weekday within a week, else a short date.
    var chatStamp: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return Formatters.time.string(from: self) }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: self), to: cal.startOfDay(for: Date())).day ?? 99
        if days < 7, days >= 0 { return Formatters.weekday.string(from: self) }
        return Formatters.shortDate.string(from: self)
    }
}

// DateFormatter is thread-safe for formatting since macOS 10.9; these are configure-once.
enum Formatters {
    static let time: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()
    static let weekday: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEE"); return f
    }()
    static let shortDate: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none; return f
    }()
    static let dayHeader: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; f.doesRelativeDateFormatting = true; return f
    }()
    static let full: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
}

extension Color {
    /// GitHub label color ("d73a4a") → Color.
    init(hexLabel: String) {
        var h = hexLabel.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

/// Stable per-login fallback color for avatar placeholders (String.hashValue is seeded per launch).
func stableAvatarColor(_ login: String) -> Color {
    let h = login.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) }
    let hue = Double(abs(h) % 360) / 360.0
    return Color(hue: hue, saturation: 0.5, brightness: 0.75)
}

/// Same hue as the avatar, tuned darker/deeper so name labels stay readable
/// on both light and dark backgrounds.
func stableNameColor(_ login: String) -> Color {
    let h = login.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) }
    let hue = Double(abs(h) % 360) / 360.0
    return Color(hue: hue, saturation: 0.62, brightness: 0.68)
}

extension Notification.Name {
    static let gcFocusSearch = Notification.Name("gitchat.focusSearch")
}
