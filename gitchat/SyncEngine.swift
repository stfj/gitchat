import Foundation

struct NotificationItem {
    var chatID: String
    var title: String
    var subtitle: String
    var body: String
}

/// Stateless GitHub operations layer: turns wire types into app models,
/// fetches transcripts, uploads images. The sync *loop* lives in AppState.
@MainActor
final class SyncEngine {
    let api: GitHubAPI
    let myLogin: String
    private var assetsRepoVerified = false

    init(api: GitHubAPI, myLogin: String) {
        self.api = api
        self.myLogin = myLogin
    }

    nonisolated static let ghost = GHUserRef(login: "ghost", avatarURL: nil)

    // MARK: model building

    func message(fromIssue issue: GHIssue) -> Message {
        Message(
            id: "body",
            commentID: nil,
            author: issue.user?.ref ?? Self.ghost,
            body: issue.body ?? "",
            createdAt: issue.createdAt,
            updatedAt: nil,
            htmlURL: issue.htmlUrl,
            attachments: Self.attachments(body: issue.body, bodyHtml: issue.bodyHtml),
            pending: false,
            failed: false
        )
    }

    func message(fromComment c: GHComment) -> Message {
        Message(
            id: String(c.id),
            commentID: c.id,
            author: c.user?.ref ?? Self.ghost,
            body: c.body ?? "",
            createdAt: c.createdAt,
            updatedAt: c.updatedAt,
            htmlURL: c.htmlUrl,
            attachments: Self.attachments(body: c.body, bodyHtml: c.bodyHtml),
            pending: false,
            failed: false
        )
    }

    // MARK: transcript

    /// Full, fresh conversation. Uses the "full" media type so body_html carries
    /// signed image URLs that work for private-repo attachments.
    func fetchTranscript(chat: Chat) async throws -> [Message] {
        let issue = try await api.issue(chat.repoFullName, chat.number)
        var messages = [message(fromIssue: issue)]
        let comments = try await api.comments(chat.repoFullName, chat.number, since: nil, full: true)
        messages += comments.map { message(fromComment: $0) }
        messages.sort { $0.createdAt < $1.createdAt }
        return messages
    }

    /// Comments newer than the chat's last known message.
    func newMessages(for chat: Chat) async throws -> [Message] {
        let comments = try await api.comments(chat.repoFullName, chat.number,
                                              since: chat.lastMessageAt.addingTimeInterval(-2), full: false)
        return comments.map { message(fromComment: $0) }
            .filter { $0.createdAt > chat.lastMessageAt }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: image uploads

    /// Commits the image to a public `<login>/<assetsRepo>` repo (created on first
    /// use) and returns a raw URL that renders both here and on github.com.
    /// The API offers no way to push to GitHub's own user-attachments host.
    func uploadImage(data: Data, fileName: String, assetsRepo: String) async throws -> String {
        let full = "\(myLogin)/\(assetsRepo)"
        if !assetsRepoVerified {
            do {
                _ = try await api.repoInfo(full)
            } catch APIError.notFound {
                _ = try await api.createUserRepo(
                    name: assetsRepo,
                    description: "Images attached to issues via gitchat"
                )
                try? await Task.sleep(for: .seconds(2))   // let repo creation settle
            }
            assetsRepoVerified = true
        }
        let stem = (fileName as NSString).deletingPathExtension
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        var ext = (fileName as NSString).pathExtension.lowercased()
        if ext.isEmpty { ext = "png" }
        let path = "img/\(UUID().uuidString.prefix(8))-\(stem.isEmpty ? "image" : stem).\(ext)"
        let result = try await api.putFile(repo: full, path: path,
                                           base64: data.base64EncodedString(),
                                           message: "Attach \(fileName) (via gitchat)")
        guard let url = result.content?.downloadUrl else {
            throw APIError.http(500, "upload returned no URL")
        }
        return url
    }

    // MARK: markdown/html mining

    nonisolated static func imageURLs(html: String) -> [String] {
        matches(pattern: "<img[^>]*?src=\"([^\"]+)\"", in: html)
    }

    nonisolated static func imageURLs(markdown: String) -> [String] {
        matches(pattern: "!\\[[^\\]]*\\]\\(([^)\\s]+)[^)]*\\)", in: markdown)
    }

    nonisolated private static func matches(pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }

    /// Image attachments for a message. body_html (when present) carries signed
    /// URLs that also work for private repos, so it wins over raw markdown.
    nonisolated static func attachments(body: String?, bodyHtml: String?) -> [Attachment] {
        let fromHTML = bodyHtml.map { imageURLs(html: $0) } ?? []
        let fromMD = body.map { imageURLs(markdown: $0) } ?? []
        let chosen = fromHTML.isEmpty ? fromMD : fromHTML
        var seen = Set<String>()
        return chosen.compactMap { url in
            guard seen.insert(url).inserted else { return nil }
            return Attachment(url: url, alt: nil, isImage: true)
        }
    }

    /// Message body with image markup removed (images render as separate bubbles).
    nonisolated static func displayBody(_ body: String?) -> String {
        guard var s = body, !s.isEmpty else { return "" }
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "<img[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
