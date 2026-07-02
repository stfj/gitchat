import SwiftUI
import AppKit
import Combine

enum AppPhase {
    case loading
    case loggedOut
    case ready
}

struct ChatRowModel: Identifiable {
    var chat: Chat
    var id: String { chat.id }
}

struct PendingAttachment: Identifiable {
    enum UploadState {
        case uploading
        case uploaded(String)
        case failed
    }
    let id = UUID()
    var fileName: String
    var thumbnail: NSImage?
    var state: UploadState = .uploading
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var phase: AppPhase = .loading
    @Published var me: GHUserRef?
    @Published var chats: [String: Chat] = [:] { didSet { unreadDidChange() } }
    @Published var transcripts: [String: [Message]] = [:]
    @Published var repos: [RepoInfo] = []
    @Published var selectedChatID: String? {
        didSet {
            guard oldValue != selectedChatID, let id = selectedChatID else { return }
            // Defer: selection changes arrive mid view-update.
            Task { @MainActor in self.chatOpened(id) }
        }
    }
    @Published var searchText = ""
    @Published var filter: ChatFilter = .all
    @Published var settings = AppSettings() { didSet { store.saveSettings(settings) } }
    @Published var syncStatusText = ""
    @Published var lastErrorText: String?
    @Published var composeVisible = false
    @Published var previewImageURL: String?
    @Published var jumpTarget: MessageJump?
    @Published var highlightedMessageID: String?
    @Published var webLoginVisible = false
    @Published var webSessionActive = false
    @Published var editingMessage: EditingTarget?
    @Published var editDraft = ""
    @Published var editSaving = false
    @Published var transcriptLoading: Set<String> = []

    struct EditingTarget: Equatable {
        var chatID: String
        var messageID: String
    }
    // Not @Published on purpose: publishing per-keystroke re-rendered the
    // whole window. The composer keeps its own @State and syncs here.
    var drafts: [String: String] = [:]

    var onUnreadChanged: ((Int) -> Void)?
    var onShowWindow: (() -> Void)?

    let store = Store()
    private(set) var api: GitHubAPI?
    private(set) var engine: SyncEngine?
    private var meta = StoreMeta()
    private var syncLoopTask: Task<Void, Never>?
    private var cycleRunning = false
    private(set) var windowIsKey = false
    // GitHub's list API lags writes; these keep refreshes from briefly
    // resurrecting deleted comments or reverting fresh edits.
    private var recentlyDeleted: [String: Date] = [:]
    private var recentEdits: [String: (message: Message, at: Date)] = [:]

    // MARK: - Lifecycle

    func bootstrap() {
        settings = store.loadSettings()
        if let creds = CredentialsVault.load() {
            Task { await start(with: creds) }
        } else if let envToken = ProcessInfo.processInfo.environment["GITCHAT_TOKEN"],
                  !envToken.isEmpty {
            // Dev/testing convenience: transient login, nothing persisted.
            Task {
                do { try await signIn(token: envToken, baseURL: settings.apiBase, persist: false) }
                catch {
                    gclog("env token sign-in failed: \(error.localizedDescription)")
                    phase = .loggedOut
                }
            }
        } else {
            phase = .loggedOut
        }
    }

    func signIn(token: String, baseURL: String, persist: Bool = true) async throws {
        let api = GitHubAPI(token: token, baseURL: baseURL)
        let user = try await api.me()
        let creds = Credentials(token: token, login: user.login, baseURL: api.baseURL)
        if persist { CredentialsVault.save(creds) }
        await start(with: creds, prebuiltAPI: api, user: user.ref)
    }

    private func start(with creds: Credentials, prebuiltAPI: GitHubAPI? = nil, user: GHUserRef? = nil) async {
        let api = prebuiltAPI ?? GitHubAPI(token: creds.token, baseURL: creds.baseURL)
        self.api = api
        self.engine = SyncEngine(api: api, myLogin: creds.login)
        settings.apiBase = api.baseURL
        if let user {
            me = user
        } else {
            me = GHUserRef(login: creds.login, avatarURL: nil)
            Task { if let u = try? await api.me() { self.me = u.ref } }
        }
        chats = store.loadChats()
        repos = store.loadRepos()
        meta = store.loadMeta()
        phase = .ready
        Notifier.shared.configure()
        gclog("signed in as \(creds.login); \(chats.count) cached chats")
        Task { await store.buildSearchIndex(chats: chats) }
        Task { self.webSessionActive = await WebSession.shared.hasSession() }
        startSyncLoop()
        if ProcessInfo.processInfo.environment["GITCHAT_DEBUG_GEO"] != nil {
            Task {
                try? await Task.sleep(for: .seconds(2))
                if let longest = self.chats.values.max(by: { $0.title.count < $1.title.count }) {
                    gclog("debug auto-select longest title (\(longest.title.count) chars): \(longest.id)")
                    self.selectedChatID = longest.id
                }
                try? await Task.sleep(for: .seconds(3))
                let results = self.searchResults("the")
                gclog("debug search 'the': \(results.chats.count) chat hit(s), \(results.messages.count) message hit(s)")
                if let hit = results.messages.first(where: { $0.messageID != "body" && $0.messageID != "fallback" }) {
                    gclog("debug opening hit: \(hit.chatID) message \(hit.messageID)")
                    self.open(hit: hit)
                }
            }
        }
    }

    func signOut() {
        syncLoopTask?.cancel()
        syncLoopTask = nil
        CredentialsVault.clear()
        api = nil
        engine = nil
        me = nil
        selectedChatID = nil
        chats = [:]
        transcripts = [:]
        repos = []
        drafts = [:]
        meta = StoreMeta()
        store.wipe()
        phase = .loggedOut
    }

    private func startSyncLoop() {
        syncLoopTask?.cancel()
        syncLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runCycle()
                let seconds = await MainActor.run { self?.settings.pollSeconds ?? 60 }
                try? await Task.sleep(for: .seconds(max(30, seconds)))
            }
        }
    }

    func syncNow() {
        Task { await runCycle() }
    }

    // MARK: - Sync cycle

    func runCycle() async {
        guard let api, phase == .ready, !cycleRunning else { return }
        cycleRunning = true
        defer { cycleRunning = false }
        syncStatusText = "Syncing…"

        let isInitial = !meta.initialSyncDone
        let cycleStart = Date()
        let historyStart = Calendar.current.date(byAdding: .day, value: -settings.historyDays, to: cycleStart)
            ?? cycleStart.addingTimeInterval(-30 * 86400)
        var notifications: [NotificationItem] = []
        var failures: [String] = []

        // 1. Repo inventory (compose picker + per-repo sweep schedule).
        do {
            var incoming = try await api.myRepos()
            if meta.cyclesRun % 10 == 0 {
                incoming += (try? await api.watchedRepos()) ?? []
            }
            mergeRepos(incoming)
        } catch {
            failures.append("repos: \(error.localizedDescription)")
        }

        // 2. Firehose: every visible issue updated since last cycle, one cheap call.
        do {
            let since = meta.lastFirehose ?? historyStart
            let issues = try await api.firehoseIssues(since: since)
            if !issues.isEmpty { gclog("firehose: \(issues.count) updated issue(s)") }
            for issue in issues {
                guard let repoName = issue.repoFullName else { continue }
                if let n = await upsert(issue: issue, repo: repoName, isInitial: isInitial) {
                    notifications.append(n)
                }
            }
            meta.lastFirehose = cycleStart.addingTimeInterval(-120)   // overlap; updatedAt guard dedupes
        } catch {
            failures.append("issues: \(error.localizedDescription)")
        }

        // 3. Round-robin sweep of individual repos (catches anything the firehose
        //    misses, e.g. repos where issues exist but the account isn't a member).
        if api.rateRemaining > 300, failures.isEmpty || !isInitial {
            let due = dueRepos(historyStart: historyStart, limit: isInitial ? 25 : 10)
            for repo in due {
                do {
                    let issues = try await api.repoIssues(repo.fullName, since: repo.lastIssueSync ?? historyStart)
                    for issue in issues {
                        if let n = await upsert(issue: issue, repo: repo.fullName, isInitial: isInitial) {
                            notifications.append(n)
                        }
                    }
                    markRepoSynced(repo.fullName, at: cycleStart)
                } catch APIError.notFound {
                    markRepoSynced(repo.fullName, at: cycleStart)   // issues disabled / gone
                } catch {
                    failures.append("\(repo.fullName): \(error.localizedDescription)")
                    break
                }
            }
        }

        // 4. Transcript backfill so search and chat-open are instant.
        if api.rateRemaining > 500 {
            let needing = chats.values
                .filter { $0.transcriptSyncedAt == nil }
                .sorted { $0.lastMessageAt > $1.lastMessageAt }
                .prefix(isInitial ? 12 : 6)
            for chat in needing {
                await refreshTranscript(chatID: chat.id, quiet: true)
            }
        }

        if isInitial { meta.initialSyncDone = true }
        meta.cyclesRun += 1
        store.saveMeta(meta)
        store.saveChats(chats)
        store.saveRepos(repos)

        if settings.notificationsEnabled {
            for n in notifications { Notifier.shared.post(n) }
        }

        if failures.isEmpty {
            syncStatusText = "Updated \(Formatters.time.string(from: Date()))"
        } else {
            syncStatusText = "Sync problem — retrying"
            gclog("sync failures: \(failures.joined(separator: " | "))")
            if failures.contains(where: { $0.contains("401") }) {
                lastErrorText = "GitHub rejected the token. Sign in again from Settings."
            }
        }
        gclog("cycle done: \(chats.count) chats, \(notifications.count) notification(s), rate \(api.rateRemaining)")
    }

    /// Merge one issue payload into the chat list. Returns a notification to post, if any.
    private func upsert(issue: GHIssue, repo: String, isInitial: Bool) async -> NotificationItem? {
        guard issue.pullRequest == nil || settings.includePullRequests else { return nil }
        guard let engine else { return nil }
        let id = Chat.key(repo: repo, number: issue.number)
        let labels = (issue.labels ?? []).map { LabelTag(name: $0.name, colorHex: $0.color ?? "8b949e") }
        let assignees = (issue.assignees ?? []).map { $0.ref }
        let author = issue.user?.ref ?? SyncEngine.ghost

        if var chat = chats[id] {
            guard issue.updatedAt > chat.updatedAt else { return nil }
            let oldCount = chat.commentCount
            chat.title = issue.title
            chat.state = issue.state
            chat.labels = labels
            chat.assignees = assignees
            chat.commentCount = issue.comments ?? chat.commentCount
            chat.updatedAt = issue.updatedAt
            var notification: NotificationItem?

            if chat.commentCount > oldCount, !chat.ignored {
                if let fresh = try? await engine.newMessages(for: chat), !fresh.isEmpty {
                    if let last = fresh.last {
                        chat.lastMessageAt = last.createdAt
                        chat.lastMessageSnippet = plainSnippet(last.body)
                        chat.lastMessageAuthor = last.author
                    }
                    appendTranscript(chat: chat, fresh)
                    let fromOthers = fresh.filter { $0.author.login != engine.myLogin }
                    let viewingNow = selectedChatID == id && windowIsKey
                    if !fromOthers.isEmpty, !isInitial, !viewingNow {
                        chat.unreadCount += fromOthers.count
                        if let last = fromOthers.last {
                            notification = NotificationItem(
                                chatID: id,
                                title: chat.title,
                                subtitle: "\(repo) #\(chat.number) · \(last.author.login)",
                                body: (fromOthers.count > 1 ? "\(fromOthers.count) new messages · " : "")
                                    + plainSnippet(last.body, limit: 140)
                            )
                        }
                    }
                }
            }
            chats[id] = chat
            return notification
        } else {
            let bodyText = SyncEngine.displayBody(issue.body)
            var chat = Chat(
                id: id,
                repoFullName: repo,
                number: issue.number,
                title: issue.title,
                isPullRequest: issue.pullRequest != nil,
                state: issue.state,
                author: author,
                assignees: assignees,
                labels: labels,
                commentCount: issue.comments ?? 0,
                htmlURL: issue.htmlUrl,
                createdAt: issue.createdAt,
                updatedAt: issue.updatedAt,
                lastMessageAt: (issue.comments ?? 0) > 0 ? issue.updatedAt : issue.createdAt,
                lastMessageSnippet: bodyText.isEmpty ? issue.title : plainSnippet(bodyText),
                lastMessageAuthor: author,
                unreadCount: 0,
                pinned: false,
                ignored: false,
                transcriptSyncedAt: nil
            )
            var notification: NotificationItem?
            if !isInitial, author.login != engine.myLogin {
                chat.unreadCount = 1
                notification = NotificationItem(
                    chatID: id,
                    title: "New issue: \(issue.title)",
                    subtitle: "\(repo) #\(issue.number) · \(author.login)",
                    body: plainSnippet(bodyText.isEmpty ? issue.title : bodyText, limit: 140)
                )
            }
            chats[id] = chat
            store.indexChat(chat, body: bodyText)
            return notification
        }
    }

    private func mergeRepos(_ incoming: [GHRepo]) {
        var map = Dictionary(repos.map { ($0.fullName, $0) }, uniquingKeysWith: { a, _ in a })
        for r in incoming {
            var info = map[r.fullName] ?? RepoInfo(
                fullName: r.fullName, isPrivate: r.isPrivate ?? false,
                hasIssues: r.hasIssues ?? true, archived: r.archived ?? false,
                canPush: r.permissions?.push ?? false, pushedAt: r.pushedAt,
                lastIssueSync: nil, ownerAvatarURL: r.owner?.avatarUrl
            )
            info.isPrivate = r.isPrivate ?? info.isPrivate
            info.hasIssues = r.hasIssues ?? info.hasIssues
            info.archived = r.archived ?? info.archived
            info.canPush = r.permissions?.push ?? info.canPush
            info.pushedAt = r.pushedAt ?? info.pushedAt
            info.ownerAvatarURL = r.owner?.avatarUrl ?? info.ownerAvatarURL
            info.repoID = r.id ?? info.repoID
            map[r.fullName] = info
        }
        repos = Array(map.values)
    }

    private func markRepoSynced(_ fullName: String, at date: Date) {
        guard let i = repos.firstIndex(where: { $0.fullName == fullName }) else { return }
        repos[i].lastIssueSync = date
    }

    private func dueRepos(historyStart: Date, limit: Int) -> [RepoInfo] {
        let reposWithChats = Set(chats.values.map(\.repoFullName))
        return repos
            .filter { $0.hasIssues && !$0.archived }
            .filter {
                ($0.pushedAt ?? .distantPast) > historyStart
                    || reposWithChats.contains($0.fullName)
                    || $0.lastIssueSync == nil
            }
            .sorted { ($0.lastIssueSync ?? .distantPast) < ($1.lastIssueSync ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Transcripts

    private func chatOpened(_ id: String) {
        guard let chat = chats[id] else { return }
        if transcripts[id] == nil, let cached = store.loadTranscript(chat) {
            transcripts[id] = cached
        }
        Task { await refreshTranscript(chatID: id) }
        markRead(id)
        Notifier.shared.clearDelivered(for: id)
    }

    func refreshTranscript(chatID: String, quiet: Bool = false) async {
        guard let engine, var chat = chats[chatID] else { return }
        if !quiet { transcriptLoading.insert(chatID) }
        defer { transcriptLoading.remove(chatID) }
        do {
            var messages = try await engine.fetchTranscript(chat: chat)
            // GitHub's comment list lags just-posted comments; a blind replace
            // here made fresh sends vanish until the API caught up. Keep local
            // messages the server doesn't know about yet, drop ones we just
            // deleted, and prefer fresh local edits over stale server copies.
            let now = Date()
            recentlyDeleted = recentlyDeleted.filter { now.timeIntervalSince($0.value) < 300 }
            recentEdits = recentEdits.filter { now.timeIntervalSince($0.value.at) < 300 }
            messages.removeAll { recentlyDeleted[$0.id] != nil }
            messages = messages.map { m in
                if let edit = recentEdits[m.id], (m.updatedAt ?? .distantPast) < edit.at {
                    return edit.message
                }
                return m
            }
            if let current = transcripts[chatID] {
                let known = Set(messages.map(\.id))
                let recentCutoff = now.addingTimeInterval(-300)
                for m in current where !known.contains(m.id) {
                    if m.pending || m.failed || (m.commentID != nil && m.createdAt > recentCutoff) {
                        messages.append(m)
                    }
                }
                messages.sort { $0.createdAt < $1.createdAt }
            }
            if !quiet || transcripts[chatID] != nil {
                transcripts[chatID] = messages
            }
            chat.transcriptSyncedAt = Date()
            if let last = messages.last {
                chat.lastMessageAt = last.createdAt
                chat.lastMessageSnippet = plainSnippet(last.body.isEmpty ? chat.title : last.body)
                chat.lastMessageAuthor = last.author
                chat.commentCount = max(0, messages.count - 1)
            }
            chats[chatID] = chat
            store.saveTranscript(chat, messages)
        } catch {
            if !quiet {
                lastErrorText = "Couldn't load the conversation: \(error.localizedDescription)"
            }
        }
    }

    private func appendTranscript(chat: Chat, _ fresh: [Message]) {
        var list = transcripts[chat.id] ?? store.loadTranscript(chat) ?? []
        guard !list.isEmpty else {
            store.appendIndex(chatID: chat.id, messages: fresh)
            return
        }
        let known = Set(list.map(\.id))
        list += fresh.filter { !known.contains($0.id) }
        list.sort { $0.createdAt < $1.createdAt }
        if transcripts[chat.id] != nil { transcripts[chat.id] = list }
        store.saveTranscript(chat, list)
    }

    // MARK: - Sending

    func sendMessage(chatID: String, text: String, attachments: [PendingAttachment]) {
        guard let api, let engine, let chat = chats[chatID] else { return }
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var atts: [Attachment] = []
        for a in attachments {
            if case .uploaded(let url) = a.state {
                body += "\n\n![\(a.fileName)](\(url))"
                atts.append(Attachment(url: url, alt: a.fileName, isImage: true))
            }
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        let localID = "local-\(UUID().uuidString)"
        let local = Message(
            id: localID, commentID: nil,
            author: me ?? GHUserRef(login: engine.myLogin, avatarURL: nil),
            body: body, createdAt: Date(), updatedAt: nil, htmlURL: nil,
            attachments: atts, pending: true, failed: false
        )
        transcripts[chatID, default: []].append(local)

        Task {
            do {
                let posted = try await api.postComment(chat.repoFullName, chat.number, body: body)
                let real = engine.message(fromComment: posted)
                self.replaceLocal(chatID: chatID, localID: localID, with: real)
                if var c = self.chats[chatID] {
                    c.commentCount += 1
                    c.lastMessageAt = real.createdAt
                    c.lastMessageSnippet = plainSnippet(real.body)
                    c.lastMessageAuthor = real.author
                    c.updatedAt = max(c.updatedAt, real.createdAt)
                    self.chats[chatID] = c
                    self.store.saveChats(self.chats)
                    if let full = self.transcripts[chatID] {
                        self.store.saveTranscript(c, full)
                    }
                }
            } catch {
                self.markLocalFailed(chatID: chatID, localID: localID)
                self.lastErrorText = "Message didn't send: \(error.localizedDescription)"
            }
        }
    }

    private func replaceLocal(chatID: String, localID: String, with real: Message) {
        guard var list = transcripts[chatID] else { return }
        list.removeAll { $0.id == localID }
        if !list.contains(where: { $0.id == real.id }) { list.append(real) }
        list.sort { $0.createdAt < $1.createdAt }
        transcripts[chatID] = list
    }

    private func markLocalFailed(chatID: String, localID: String) {
        guard var list = transcripts[chatID],
              let i = list.firstIndex(where: { $0.id == localID }) else { return }
        list[i].pending = false
        list[i].failed = true
        transcripts[chatID] = list
    }

    // MARK: - Editing own messages

    func beginEdit(chatID: String, message: Message) {
        guard message.author.login == me?.login, !message.pending, !message.failed else { return }
        editDraft = message.body
        editingMessage = EditingTarget(chatID: chatID, messageID: message.id)
    }

    func cancelEdit() {
        editingMessage = nil
        editDraft = ""
    }

    func commitEdit() async {
        guard let target = editingMessage, let api, let engine,
              let chat = chats[target.chatID] else { return }
        let newBody = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newBody.isEmpty else { return }
        editSaving = true
        defer { editSaving = false }
        do {
            let updated: Message
            if target.messageID == "body" {
                let issue = try await api.updateIssueBody(chat.repoFullName, chat.number, body: newBody)
                updated = engine.message(fromIssue: issue)
                mutateChat(target.chatID) { $0.updatedAt = max($0.updatedAt, issue.updatedAt) }
            } else if let existing = transcripts[target.chatID]?.first(where: { $0.id == target.messageID }),
                      let commentID = existing.commentID {
                let comment = try await api.updateComment(chat.repoFullName, commentID: commentID, body: newBody)
                updated = engine.message(fromComment: comment)
            } else {
                cancelEdit()
                return
            }
            recentEdits[updated.id] = (message: updated, at: Date())
            if var list = transcripts[target.chatID],
               let i = list.firstIndex(where: { $0.id == target.messageID }) {
                list[i] = updated
                transcripts[target.chatID] = list
                store.saveTranscript(chat, list)
                if list.last?.id == updated.id {
                    mutateChat(target.chatID) {
                        $0.lastMessageSnippet = plainSnippet(updated.body)
                        $0.lastMessageAuthor = updated.author
                    }
                }
            }
            cancelEdit()
        } catch {
            lastErrorText = "Couldn't save the edit: \(error.localizedDescription)"
        }
    }

    /// Delete one of my comments (the issue body itself can't be deleted).
    func deleteMessage(chatID: String, messageID: String) {
        guard let api, let chat = chats[chatID],
              let message = transcripts[chatID]?.first(where: { $0.id == messageID }),
              message.author.login == me?.login,
              let commentID = message.commentID else { return }
        Task {
            do {
                try await api.deleteComment(chat.repoFullName, commentID: commentID)
                self.recentlyDeleted[messageID] = Date()
                if var list = self.transcripts[chatID] {
                    list.removeAll { $0.id == messageID }
                    self.transcripts[chatID] = list
                    self.store.saveTranscript(chat, list)
                    self.mutateChat(chatID) {
                        $0.commentCount = max(0, $0.commentCount - 1)
                        if let last = list.last {
                            $0.lastMessageAt = last.createdAt
                            $0.lastMessageSnippet = plainSnippet(last.body.isEmpty ? $0.title : last.body)
                            $0.lastMessageAuthor = last.author
                        }
                    }
                }
            } catch {
                self.lastErrorText = "Couldn't delete the message: \(error.localizedDescription)"
            }
        }
    }

    func retryMessage(chatID: String, messageID: String) {
        guard var list = transcripts[chatID],
              let i = list.firstIndex(where: { $0.id == messageID }) else { return }
        let body = list[i].body
        list.remove(at: i)
        transcripts[chatID] = list
        sendMessage(chatID: chatID, text: body, attachments: [])
    }

    /// Upload an image, private-first: GitHub's own attachment host (scoped to
    /// the repo's visibility) when enabled, else the legacy public assets repo.
    func upload(data: Data, fileName: String, repoFullName: String?) async throws -> String {
        guard let engine else { throw APIError.unauthorized }

        let canUsePrivate = settings.privateAttachments
            && settings.apiBase == "https://api.github.com"   // web flow is github.com-only
        guard canUsePrivate else {
            return try await engine.uploadImage(data: data, fileName: fileName,
                                                assetsRepo: settings.assetsRepoName)
        }

        guard let repoFullName else { throw AttachmentError.needsRepo }
        guard let cookieHeader = await WebSession.shared.cookieHeader() else {
            webSessionActive = false
            webLoginVisible = true   // pop the sign-in sheet; user retries after
            throw AttachmentError.needsWebLogin
        }
        let repoID = try await repoID(for: repoFullName)
        let ext = (fileName as NSString).pathExtension
        let href = try await UserAttachmentUploader.shared.upload(
            data: data,
            fileName: fileName,
            contentType: UserAttachmentUploader.contentType(forExtension: ext),
            repoFullName: repoFullName,
            repositoryID: repoID,
            cookieHeader: cookieHeader
        )
        webSessionActive = true
        return href
    }

    private func repoID(for fullName: String) async throws -> Int {
        if let cached = repos.first(where: { $0.fullName == fullName })?.repoID {
            return cached
        }
        guard let api else { throw APIError.unauthorized }
        let info = try await api.repoInfo(fullName)
        guard let id = info.id else { throw APIError.http(500, "repository id unavailable") }
        if let i = repos.firstIndex(where: { $0.fullName == fullName }) {
            repos[i].repoID = id
        }
        return id
    }

    // MARK: - New issues

    func createIssue(repo: String, title: String, body: String,
                     labels: [String], assignees: [String]) async throws {
        guard let api else { throw APIError.unauthorized }
        let issue = try await api.createIssue(repo, title: title, body: body,
                                              labels: labels, assignees: assignees)
        if !labels.isEmpty {
            for label in labels { meta.labelUsage[label, default: 0] += 1 }
            store.saveMeta(meta)
        }
        _ = await upsert(issue: issue, repo: repo, isInitial: false)
        store.saveChats(chats)
        selectedChatID = Chat.key(repo: repo, number: issue.number)
        onShowWindow?()
    }

    /// How often the user has applied this label when creating issues.
    func labelUsage(_ name: String) -> Int {
        meta.labelUsage[name] ?? 0
    }

    // MARK: - @mention autocomplete

    @Published private(set) var assignableUsers: [String: [GHUserRef]] = [:]
    private var assignableFetching: Set<String> = []

    /// Lazily fetch a repo's assignable users the first time a mention popup opens there.
    func ensureAssignables(for repo: String) {
        guard assignableUsers[repo] == nil, !assignableFetching.contains(repo), let api else { return }
        assignableFetching.insert(repo)
        Task {
            let users = (try? await api.assignableUsers(repo)) ?? []
            self.assignableUsers[repo] = users.map { $0.ref }
            self.assignableFetching.remove(repo)
        }
    }

    /// Ranked candidates: most recent speakers in this chat first, then
    /// assignees and the issue author, then the repo's collaborators.
    func mentionCandidates(chatID: String, prefix: String) -> [GHUserRef] {
        guard let chat = chats[chatID] else { return [] }
        var out: [GHUserRef] = []
        var seen = Set<String>()
        let myLogin = me?.login.lowercased() ?? ""
        func add(_ u: GHUserRef) {
            let key = u.login.lowercased()
            guard key != "ghost", key != myLogin, seen.insert(key).inserted else { return }
            out.append(u)
        }
        for message in (transcripts[chatID] ?? []).reversed() { add(message.author) }
        chat.assignees.forEach { add($0) }
        add(chat.author)
        (assignableUsers[chat.repoFullName] ?? []).forEach { add($0) }

        let p = prefix.lowercased()
        guard !p.isEmpty else { return Array(out.prefix(6)) }
        let matching = out.filter { $0.login.lowercased().contains(p) }
        let prefixed = matching.filter { $0.login.lowercased().hasPrefix(p) }
        let rest = matching.filter { !$0.login.lowercased().hasPrefix(p) }
        return Array((prefixed + rest).prefix(6))
    }

    func fetchRepoMeta(_ repo: String) async -> (labels: [GHLabel], assignees: [GHUser]) {
        guard let api else { return ([], []) }
        async let l = (try? api.labels(repo)) ?? []
        async let a = (try? api.assignableUsers(repo)) ?? []
        return await (l, a)
    }

    /// Repos for the compose picker: most recent chat activity first, then push recency.
    func repoChoices() -> [RepoInfo] {
        var latest: [String: Date] = [:]
        for c in chats.values {
            latest[c.repoFullName] = max(latest[c.repoFullName] ?? .distantPast, c.lastMessageAt)
        }
        return repos
            .filter { $0.hasIssues && !$0.archived }
            .sorted {
                let a = latest[$0.fullName] ?? $0.pushedAt ?? .distantPast
                let b = latest[$1.fullName] ?? $1.pushedAt ?? .distantPast
                if a != b { return a > b }
                return $0.fullName.lowercased() < $1.fullName.lowercased()
            }
    }

    // MARK: - Chat actions

    private func mutateChat(_ id: String, _ change: (inout Chat) -> Void) {
        guard var c = chats[id] else { return }
        change(&c)
        chats[id] = c
        store.saveChats(chats)
    }

    func togglePin(_ id: String) {
        mutateChat(id) { $0.pinned.toggle() }
    }

    func toggleIgnore(_ id: String) {
        mutateChat(id) {
            $0.ignored.toggle()
            if $0.ignored { $0.unreadCount = 0 }
        }
    }

    func markRead(_ id: String) {
        guard let c = chats[id], c.unreadCount != 0 else { return }
        mutateChat(id) { $0.unreadCount = 0 }
    }

    func markUnread(_ id: String) {
        mutateChat(id) { $0.unreadCount = max(1, $0.unreadCount) }
    }

    func markAllRead() {
        for (k, v) in chats where v.unreadCount > 0 {
            var c = v
            c.unreadCount = 0
            chats[k] = c
        }
        store.saveChats(chats)
    }

    func openInSafari(_ id: String) {
        guard let chat = chats[id], let url = URL(string: chat.htmlURL) else { return }
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        if FileManager.default.fileExists(atPath: safari.path) {
            NSWorkspace.shared.open([url], withApplicationAt: safari,
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func toggleClosed(_ id: String) {
        guard let api, let chat = chats[id] else { return }
        Task {
            do {
                let issue = try await api.setIssueState(chat.repoFullName, chat.number,
                                                        closed: chat.isOpen)
                self.mutateChat(id) {
                    $0.state = issue.state
                    $0.updatedAt = max($0.updatedAt, issue.updatedAt)
                }
            } catch {
                self.lastErrorText = "Couldn't change issue state: \(error.localizedDescription)"
            }
        }
    }

    func windowFocusChanged(isKey: Bool) {
        windowIsKey = isKey
        if isKey, let id = selectedChatID { markRead(id) }
    }

    // MARK: - Derived lists

    var unreadChatCount: Int {
        chats.values.filter { !$0.ignored && $0.unreadCount > 0 }.count
    }

    private func unreadDidChange() {
        onUnreadChanged?(unreadChatCount)
    }

    func pinnedChats() -> [Chat] {
        chats.values
            .filter { $0.pinned && !$0.ignored }
            .sorted { $0.lastMessageAt > $1.lastMessageAt }
    }

    func rows() -> [ChatRowModel] {
        var list: [Chat]
        switch filter {
        case .all:
            list = chats.values.filter { !$0.ignored && !$0.pinned }
            // Closed issues hide once read and deselected (filter-menu toggle).
            if !settings.showClosed {
                list = list.filter { $0.isOpen || $0.unreadCount > 0 || $0.id == selectedChatID }
            }
        case .unread:
            list = chats.values.filter { !$0.ignored && $0.unreadCount > 0 }
        case .ignored:
            list = chats.values.filter { $0.ignored }
        }
        return list
            .sorted { $0.lastMessageAt > $1.lastMessageAt }
            .map { ChatRowModel(chat: $0) }
    }

    // MARK: - Search

    /// Full search: chats whose title/repo/author match, plus every individual
    /// message whose text contains the query.
    func searchResults(_ query: String) -> (chats: [ChatRowModel], messages: [MessageHit]) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return ([], []) }

        var chatHits: [ChatRowModel] = []
        for chat in chats.values {
            if chat.title.range(of: q, options: .caseInsensitive) != nil
                || chat.repoFullName.range(of: q, options: .caseInsensitive) != nil
                || chat.author.login.range(of: q, options: .caseInsensitive) != nil
                || "#\(chat.number)" == q {
                chatHits.append(ChatRowModel(chat: chat))
            }
        }
        chatHits.sort { $0.chat.lastMessageAt > $1.chat.lastMessageAt }

        var hits: [MessageHit] = []
        outer: for (chatID, entries) in store.messageIndex {
            guard let chat = chats[chatID] else { continue }
            for entry in entries {
                guard let r = entry.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
                let start = entry.text.index(r.lowerBound, offsetBy: -30, limitedBy: entry.text.startIndex) ?? entry.text.startIndex
                let end = entry.text.index(r.upperBound, offsetBy: 90, limitedBy: entry.text.endIndex) ?? entry.text.endIndex
                var snippet = String(entry.text[start..<end])
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if start > entry.text.startIndex { snippet = "…" + snippet }
                hits.append(MessageHit(
                    chatID: chatID,
                    messageID: entry.id,
                    chatTitle: chat.title,
                    repoLine: "\(chat.repoFullName) #\(chat.number)",
                    author: entry.author,
                    snippet: snippet,
                    createdAt: entry.createdAt
                ))
                if hits.count >= 60 { break outer }
            }
        }
        hits.sort { $0.createdAt > $1.createdAt }
        return (chatHits, hits)
    }

    /// Open a message search hit: select its chat, scroll to the message, flash it.
    func open(hit: MessageHit) {
        jumpTarget = MessageJump(chatID: hit.chatID, messageID: hit.messageID)
        highlightedMessageID = hit.messageID
        selectedChatID = hit.chatID
        let flashed = hit.messageID
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            if self.highlightedMessageID == flashed { self.highlightedMessageID = nil }
        }
    }
}
