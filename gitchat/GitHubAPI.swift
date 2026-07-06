import Foundation

enum APIError: LocalizedError {
    case badURL
    case unauthorized
    case notFound
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badURL: "Invalid URL"
        case .unauthorized: "GitHub rejected the token (401)"
        case .notFound: "Not found (404)"
        case .http(let code, let msg): "GitHub error \(code)\(msg.isEmpty ? "" : ": \(msg)")"
        }
    }
}

// MARK: - Wire types (GitHub REST v3, snake_case)

struct GHUser: Codable, Hashable {
    var login: String
    var avatarUrl: String?
    var name: String?
    var ref: GHUserRef { GHUserRef(login: login, avatarURL: avatarUrl) }
}

struct GHLabel: Codable, Hashable {
    var name: String
    var color: String?
}

struct GHPRMarker: Codable, Hashable {
    var url: String?
    var mergedAt: Date?
}

struct GHPullFile: Codable {
    var filename: String
    var status: String?
    var additions: Int?
    var deletions: Int?
    var patch: String?
}

struct GHIssue: Codable {
    var number: Int
    var title: String
    var body: String?
    var bodyHtml: String?
    var state: String
    var user: GHUser?
    var labels: [GHLabel]?
    var assignees: [GHUser]?
    var comments: Int?
    var createdAt: Date
    var updatedAt: Date
    var htmlUrl: String
    var pullRequest: GHPRMarker?
    var repositoryUrl: String?

    /// "owner/name" recovered from repository_url (present on the /issues firehose).
    var repoFullName: String? {
        guard let repositoryUrl, let r = repositoryUrl.range(of: "/repos/") else { return nil }
        return String(repositoryUrl[r.upperBound...])
    }
}

struct GHComment: Codable {
    var id: Int
    var user: GHUser?
    var body: String?
    var bodyHtml: String?
    var createdAt: Date
    var updatedAt: Date?
    var htmlUrl: String?
}

struct GHRepo: Codable {
    struct Perms: Codable {
        var push: Bool?
        var admin: Bool?
    }
    var id: Int?
    var fullName: String
    var owner: GHUser?
    var isPrivate: Bool?
    var hasIssues: Bool?
    var archived: Bool?
    var pushedAt: Date?
    var permissions: Perms?

    enum CodingKeys: String, CodingKey {
        case id, fullName, owner, hasIssues, archived, pushedAt, permissions
        case isPrivate = "private"
    }
}

struct GHContent: Codable {
    struct Item: Codable {
        var downloadUrl: String?
        var htmlUrl: String?
    }
    var content: Item?
}

// MARK: - Client

@MainActor
final class GitHubAPI {
    let token: String
    let baseURL: String
    private let session: URLSession
    private(set) var rateRemaining = 5000
    private(set) var rateReset: Date?

    nonisolated static let acceptJSON = "application/vnd.github+json"
    nonisolated static let acceptFull = "application/vnd.github.full+json"   // adds body_html (signed image URLs)

    init(token: String, baseURL: String = "https://api.github.com") {
        self.token = token
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        self.baseURL = base.isEmpty ? "https://api.github.com" : base
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
    }

    nonisolated static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    nonisolated(unsafe) static let iso = ISO8601DateFormatter()

    struct Raw {
        let data: Data
        let response: HTTPURLResponse
    }

    func send(_ method: String, _ path: String,
              query: [URLQueryItem] = [],
              body: [String: Any]? = nil,
              accept: String = GitHubAPI.acceptJSON) async throws -> Raw {
        let urlString = path.hasPrefix("http") ? path : baseURL + "/" + path
        guard var comps = URLComponents(string: urlString) else { throw APIError.badURL }
        if !query.isEmpty {
            comps.queryItems = (comps.queryItems ?? []) + query
        }
        guard let url = comps.url else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("gitchat-mac", forHTTPHeaderField: "User-Agent")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badURL }
        if let rem = http.value(forHTTPHeaderField: "x-ratelimit-remaining"), let n = Int(rem) { rateRemaining = n }
        if let rst = http.value(forHTTPHeaderField: "x-ratelimit-reset"), let t = TimeInterval(rst) {
            rateReset = Date(timeIntervalSince1970: t)
        }
        switch http.statusCode {
        case 200..<300:
            return Raw(data: data, response: http)
        case 401:
            throw APIError.unauthorized
        case 404, 410:
            throw APIError.notFound
        default:
            var msg = ""
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let m = obj["message"] as? String { msg = m }
            throw APIError.http(http.statusCode, msg)
        }
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], accept: String = GitHubAPI.acceptJSON) async throws -> T {
        let raw = try await send("GET", path, query: query, accept: accept)
        return try Self.decoder.decode(T.self, from: raw.data)
    }

    /// GET with Link-header pagination.
    func paged<T: Decodable>(_ path: String, query: [URLQueryItem] = [],
                             accept: String = GitHubAPI.acceptJSON, maxPages: Int = 3) async throws -> [T] {
        var out: [T] = []
        var q = query
        if !q.contains(where: { $0.name == "per_page" }) {
            q.append(URLQueryItem(name: "per_page", value: "100"))
        }
        var nextURL: String? = nil
        for _ in 0..<max(1, maxPages) {
            let raw: Raw
            if let n = nextURL {
                raw = try await send("GET", n, accept: accept)
            } else {
                raw = try await send("GET", path, query: q, accept: accept)
            }
            out += try Self.decoder.decode([T].self, from: raw.data)
            nextURL = Self.nextLink(raw.response.value(forHTTPHeaderField: "Link"))
            if nextURL == nil { break }
        }
        return out
    }

    nonisolated static func nextLink(_ header: String?) -> String? {
        guard let header else { return nil }
        for part in header.components(separatedBy: ",") {
            let segs = part.components(separatedBy: ";")
            guard segs.count >= 2 else { continue }
            let urlPart = segs[0].trimmingCharacters(in: .whitespaces)
            guard urlPart.hasPrefix("<"), urlPart.hasSuffix(">") else { continue }
            if segs.dropFirst().contains(where: { $0.trimmingCharacters(in: .whitespaces) == "rel=\"next\"" }) {
                return String(urlPart.dropFirst().dropLast())
            }
        }
        return nil
    }

    // MARK: Endpoints

    func me() async throws -> GHUser {
        try await get("user")
    }

    func myRepos() async throws -> [GHRepo] {
        try await paged("user/repos", query: [
            .init(name: "affiliation", value: "owner,collaborator,organization_member"),
            .init(name: "sort", value: "pushed"),
            .init(name: "direction", value: "desc"),
        ], maxPages: 3)
    }

    func watchedRepos() async throws -> [GHRepo] {
        try await paged("user/subscriptions", maxPages: 2)
    }

    /// Every issue the user can see, across all owned/member/org repos, most recently updated first.
    func firehoseIssues(since: Date?) async throws -> [GHIssue] {
        var q: [URLQueryItem] = [
            .init(name: "filter", value: "all"),
            .init(name: "state", value: "all"),
            .init(name: "sort", value: "updated"),
            .init(name: "direction", value: "desc"),
        ]
        if let since { q.append(.init(name: "since", value: Self.iso.string(from: since))) }
        return try await paged("issues", query: q, maxPages: 3)
    }

    func repoIssues(_ repo: String, since: Date?) async throws -> [GHIssue] {
        var q: [URLQueryItem] = [
            .init(name: "state", value: "all"),
            .init(name: "sort", value: "updated"),
            .init(name: "direction", value: "desc"),
        ]
        if let since { q.append(.init(name: "since", value: Self.iso.string(from: since))) }
        return try await paged("repos/\(repo)/issues", query: q, maxPages: 2)
    }

    func issue(_ repo: String, _ number: Int) async throws -> GHIssue {
        try await get("repos/\(repo)/issues/\(number)", accept: Self.acceptFull)
    }

    func comments(_ repo: String, _ number: Int, since: Date?, full: Bool) async throws -> [GHComment] {
        var q: [URLQueryItem] = []
        if let since { q.append(.init(name: "since", value: Self.iso.string(from: since))) }
        return try await paged("repos/\(repo)/issues/\(number)/comments", query: q,
                               accept: full ? Self.acceptFull : Self.acceptJSON, maxPages: 10)
    }

    func postComment(_ repo: String, _ number: Int, body: String) async throws -> GHComment {
        let raw = try await send("POST", "repos/\(repo)/issues/\(number)/comments",
                                 body: ["body": body], accept: Self.acceptFull)
        return try Self.decoder.decode(GHComment.self, from: raw.data)
    }

    func createIssue(_ repo: String, title: String, body: String, labels: [String], assignees: [String]) async throws -> GHIssue {
        var payload: [String: Any] = ["title": title, "body": body]
        if !labels.isEmpty { payload["labels"] = labels }
        if !assignees.isEmpty { payload["assignees"] = assignees }
        let raw = try await send("POST", "repos/\(repo)/issues", body: payload)
        return try Self.decoder.decode(GHIssue.self, from: raw.data)
    }

    func updateComment(_ repo: String, commentID: Int, body: String) async throws -> GHComment {
        let raw = try await send("PATCH", "repos/\(repo)/issues/comments/\(commentID)",
                                 body: ["body": body], accept: Self.acceptFull)
        return try Self.decoder.decode(GHComment.self, from: raw.data)
    }

    func updateIssueBody(_ repo: String, _ number: Int, body: String) async throws -> GHIssue {
        let raw = try await send("PATCH", "repos/\(repo)/issues/\(number)",
                                 body: ["body": body], accept: Self.acceptFull)
        return try Self.decoder.decode(GHIssue.self, from: raw.data)
    }

    func deleteComment(_ repo: String, commentID: Int) async throws {
        _ = try await send("DELETE", "repos/\(repo)/issues/comments/\(commentID)")
    }

    func setIssueState(_ repo: String, _ number: Int, closed: Bool) async throws -> GHIssue {
        let raw = try await send("PATCH", "repos/\(repo)/issues/\(number)",
                                 body: ["state": closed ? "closed" : "open"])
        return try Self.decoder.decode(GHIssue.self, from: raw.data)
    }

    func labels(_ repo: String) async throws -> [GHLabel] {
        try await paged("repos/\(repo)/labels", maxPages: 1)
    }

    func addAssignees(_ repo: String, _ number: Int, logins: [String]) async throws -> GHIssue {
        let raw = try await send("POST", "repos/\(repo)/issues/\(number)/assignees",
                                 body: ["assignees": logins])
        return try Self.decoder.decode(GHIssue.self, from: raw.data)
    }

    func pullFiles(_ repo: String, _ number: Int) async throws -> [GHPullFile] {
        try await paged("repos/\(repo)/pulls/\(number)/files", maxPages: 3)
    }

    func assignableUsers(_ repo: String) async throws -> [GHUser] {
        try await paged("repos/\(repo)/assignees", maxPages: 1)
    }

    func repoInfo(_ fullName: String) async throws -> GHRepo {
        try await get("repos/\(fullName)")
    }

    func createUserRepo(name: String, description: String) async throws -> GHRepo {
        let raw = try await send("POST", "user/repos", body: [
            "name": name,
            "description": description,
            "private": false,
            "auto_init": true,
        ])
        return try Self.decoder.decode(GHRepo.self, from: raw.data)
    }

    func putFile(repo: String, path: String, base64: String, message: String) async throws -> GHContent {
        let raw = try await send("PUT", "repos/\(repo)/contents/\(path)", body: [
            "message": message,
            "content": base64,
        ])
        return try Self.decoder.decode(GHContent.self, from: raw.data)
    }
}
