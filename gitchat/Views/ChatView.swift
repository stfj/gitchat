import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject var app: AppState
    let chatID: String

    /// PRs default to the plain-English summary when one exists or can be made.
    private var showSummary: Bool {
        guard let chat = app.chats[chatID], chat.isPullRequest else { return false }
        guard !app.showRawPR.contains(chatID) else { return false }
        return app.translations[chatID] != nil || app.hasAIKey
    }

    var body: some View {
        if let chat = app.chats[chatID] {
            VStack(spacing: 0) {
                chatHeader(chat)
                Divider()
                if showSummary {
                    PRSummaryView(chatID: chatID)
                } else {
                    TranscriptView(chatID: chatID)
                }
                Divider()
                ComposerView(chatID: chatID)
            }
            .navigationTitle("")
            // Solid toolbar reserves real layout space; the floating overlay
            // style lets tall (multi-line-title) headers slide underneath it.
            .toolbarBackground(.visible, for: .windowToolbar)
            .toolbar { chatToolbar(chat) }
        }
    }

    /// Full-width header above the transcript: issue titles are long and
    /// important, and the window toolbar can't fit them.
    private func chatHeader(_ chat: Chat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(chat.title)
                .font(.system(size: 16, weight: .semibold))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                StateDot(isOpen: chat.isOpen, merged: chat.prMerged ?? !chat.isPullRequest)
                Text("\(chat.repoFullName) #\(chat.number)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                if !chat.isOpen {
                    let merged = chat.prMerged ?? false
                    Text(chat.isPullRequest && merged ? "Merged" : "Closed")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(
                            chat.isPullRequest && !merged ? Color.red.opacity(0.85) : Color.purple))
                }
                if chat.isPullRequest {
                    Text("PR")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.18)))
                }
            }
            if !chat.labels.isEmpty || !chat.assignees.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chat.labels, id: \.self) { LabelChip(tag: $0) }
                        if !chat.assignees.isEmpty {
                            if !chat.labels.isEmpty {
                                Divider().frame(height: 12)
                            }
                            ForEach(chat.assignees, id: \.self) { a in
                                HStack(spacing: 3) {
                                    AvatarView(user: a, size: 14)
                                    Text(a.login).font(.system(size: 10))
                                }
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            if ProcessInfo.processInfo.environment["GITCHAT_DEBUG_GEO"] != nil {
                gclog("chatHeader global frame: y=\(Int(frame.minY)) h=\(Int(frame.height)) w=\(Int(frame.width))")
            }
        }
    }

    @ToolbarContentBuilder
    private func chatToolbar(_ chat: Chat) -> some ToolbarContent {
        ToolbarItemGroup {
            if chat.isPullRequest {
                Button {
                    app.togglePRView(chatID: chatID)
                } label: {
                    Image(systemName: showSummary ? "text.bubble" : "wand.and.stars")
                }
                .help(showSummary ? "Show the full conversation" : "Show plain-English summary")
            } else if chat.assignees.isEmpty {
                Button {
                    app.assignSelf(chatID: chatID)
                } label: {
                    Image(systemName: "person.badge.plus")
                }
                .help("Assign this issue to me")
            }

            Button {
                app.togglePin(chatID)
            } label: {
                Image(systemName: chat.pinned ? "pin.fill" : "pin")
            }
            .help(chat.pinned ? "Unpin" : "Pin to the top of the list")

            Button {
                app.toggleIgnore(chatID)
            } label: {
                Image(systemName: chat.ignored ? "bell.slash.fill" : "bell")
            }
            .help(chat.ignored ? "Stop ignoring" : "Ignore (mute notifications)")

            Button {
                app.openInSafari(chatID)
            } label: {
                Image(systemName: "safari")
            }
            .help("Open on GitHub in Safari")

            Menu {
                Button(chat.isOpen ? "Close Issue" : "Reopen Issue") { app.toggleClosed(chatID) }
                Button("Mark as Unread") { app.markUnread(chatID) }
                Button("Refresh") { Task { await app.refreshTranscript(chatID: chatID) } }
                Divider()
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(chat.htmlURL, forType: .string)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

}

// MARK: - Transcript

struct TranscriptRow: Identifiable {
    enum Kind {
        case day(String)
        case message(Message, showHeader: Bool)
    }
    var id: String
    var kind: Kind
}

func buildTranscriptRows(_ messages: [Message]) -> [TranscriptRow] {
    var out: [TranscriptRow] = []
    var lastDay: String?
    var lastAuthor: String?
    for m in messages {
        let day = Formatters.dayHeader.string(from: m.createdAt)
        if day != lastDay {
            out.append(TranscriptRow(id: "day|\(day)|\(m.id)", kind: .day(day)))
            lastDay = day
            lastAuthor = nil
        }
        out.append(TranscriptRow(id: m.id, kind: .message(m, showHeader: m.author.login != lastAuthor)))
        lastAuthor = m.author.login
    }
    return out
}

struct TranscriptView: View {
    @EnvironmentObject var app: AppState
    let chatID: String

    @State private var scrolledID: String?

    var body: some View {
        let messages = app.transcripts[chatID] ?? []
        let stillLoading = app.transcriptLoading.contains(chatID) && messages.isEmpty

        // No ScrollViewReader/scrollTo here: on macOS the scroll command
        // bubbles past the transcript and pans the whole window's content.
        // defaultScrollAnchor keeps the log pinned to the newest message, and
        // the declarative scrollPosition binding handles jump-to-message.
        let myLogin = app.me?.login
        // Plain VStack, NOT LazyVStack: lazy prefetch re-marks the window for
        // constraint passes from inside layout (LazyLayoutViewCache.signalPrefetch),
        // which pinwheels and then crashes with NSGenericException.
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if stillLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.top, 60)
                }
                ForEach(buildTranscriptRows(messages)) { row in
                    switch row.kind {
                    case .day(let label):
                        DaySeparator(label: label)
                    case .message(let message, let showHeader):
                        MessageBubbleRow(
                            chatID: chatID,
                            message: message,
                            showHeader: showHeader,
                            isMine: message.author.login == myLogin,
                            isHighlighted: app.highlightedMessageID == message.id,
                            isEditing: app.editingMessage == AppState.EditingTarget(chatID: chatID, messageID: message.id)
                        )
                        .equatable()
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
        .scrollPosition(id: $scrolledID, anchor: .center)
        .onAppear { applyJump(app.jumpTarget) }
        .onChange(of: app.jumpTarget) { _, target in applyJump(target) }
    }

    private func applyJump(_ target: MessageJump?) {
        guard let target, target.chatID == chatID else { return }
        scrolledID = target.messageID
        if ProcessInfo.processInfo.environment["GITCHAT_DEBUG_GEO"] != nil {
            gclog("jump applied: chat=\(target.chatID) message=\(target.messageID)")
        }
        Task { @MainActor in app.jumpTarget = nil }
    }
}

// MARK: - Bubbles

// Non-observing handle to AppState: rows can trigger actions without
// subscribing to every published change (that subscription made all rows
// re-render on each keystroke/sync tick — the scroll chunkiness).
// Equatable wrapper matters: with a non-Equatable env value SwiftUI can't
// prove it unchanged, which invalidates every reader on every render and
// defeats the rows' .equatable() short-circuit.
struct AppStateRef: Equatable {
    weak var value: AppState?
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.value === rhs.value }
}

private struct AppStateRefKey: EnvironmentKey {
    static let defaultValue = AppStateRef(value: nil)
}

extension EnvironmentValues {
    var appStateRef: AppState? {
        get { self[AppStateRefKey.self].value }
        set { self[AppStateRefKey.self] = AppStateRef(value: newValue) }
    }
}

struct MessageBubbleRow: View, Equatable {
    let chatID: String
    let message: Message
    let showHeader: Bool
    let isMine: Bool
    let isHighlighted: Bool
    let isEditing: Bool
    @Environment(\.appStateRef) private var appRef
    @State private var showDeleteConfirm = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.chatID == rhs.chatID
            && lhs.message == rhs.message
            && lhs.showHeader == rhs.showHeader
            && lhs.isMine == rhs.isMine
            && lhs.isHighlighted == rhs.isHighlighted
            && lhs.isEditing == rhs.isEditing
    }

    /// Same actions as the bubble's context menu, merged into the selectable
    /// text's own (system) menu so right-clicking the words works too.
    private var menuActions: MessageMenuActions {
        let editable = isMine && !message.pending && !message.failed
        var actions = MessageMenuActions()
        let msg = message
        let chat = chatID
        let ref = appRef
        if editable {
            actions.onEdit = { ref?.beginEdit(chatID: chat, message: msg) }
            if message.commentID != nil {
                actions.onDelete = { showDeleteConfirm = true }
            }
        }
        actions.onCopyAll = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(msg.body, forType: .string)
        }
        if let urlString = message.htmlURL, let url = URL(string: urlString) {
            actions.onOpenGitHub = { NSWorkspace.shared.open(url) }
        }
        return actions
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMine {
                Spacer(minLength: 90)
                VStack(alignment: .trailing, spacing: 2) {
                    if isEditing {
                        MessageEditView()
                    } else {
                        bubble(alignRight: true)
                        if message.failed { failedRow }
                    }
                }
                if showHeader {
                    AvatarView(user: message.author, size: 28)
                        .padding(.bottom, 1)
                } else {
                    Color.clear.frame(width: 28, height: 1)
                }
            } else {
                if showHeader {
                    AvatarView(user: message.author, size: 28)
                        .padding(.bottom, 1)
                } else {
                    Color.clear.frame(width: 28, height: 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if showHeader {
                        Text(message.author.login)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(stableNameColor(message.author.login))
                            .padding(.leading, 9)
                    }
                    bubble(alignRight: false)
                }
                Spacer(minLength: 90)
            }
        }
        .padding(.top, showHeader ? 7 : 0)
        .opacity(message.pending ? 0.55 : 1)
    }

    private func bubble(alignRight: Bool) -> some View {
        BubbleContent(message: message, isMine: isMine,
                      highlighted: isHighlighted,
                      actions: menuActions)
            .animation(.easeInOut(duration: 0.3), value: isHighlighted)
            .frame(maxWidth: .infinity, alignment: alignRight ? .trailing : .leading)
            .help(Formatters.full.string(from: message.createdAt))
            .contextMenu {
                if isMine, !message.pending, !message.failed {
                    Button("Edit Message") { appRef?.beginEdit(chatID: chatID, message: message) }
                    if message.commentID != nil {
                        Button("Delete Message…", role: .destructive) { showDeleteConfirm = true }
                    }
                    Divider()
                }
                Button("Copy Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.body, forType: .string)
                }
                if let urlString = message.htmlURL, let url = URL(string: urlString) {
                    Button("Open on GitHub") { NSWorkspace.shared.open(url) }
                }
            }
            .confirmationDialog("Delete this message?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    appRef?.deleteMessage(chatID: chatID, messageID: message.id)
                }
            } message: {
                Text("This removes the comment from GitHub for everyone. There's no undo.")
            }
    }

    private var failedRow: some View {
        Button {
            appRef?.retryMessage(chatID: chatID, messageID: message.id)
        } label: {
            Label("Not delivered — click to retry", systemImage: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
    }
}

/// Plain-English PR summary shown in place of the conversation (toggle in toolbar).
struct PRSummaryView: View {
    @EnvironmentObject var app: AppState
    let chatID: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 13))
                        .foregroundStyle(.purple)
                    Text("Plain-English Summary")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    if case .done(let stored) = app.translations[chatID] {
                        Text("\(stored.model) · \(stored.createdAt.chatStamp)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                switch app.translations[chatID] {
                case .loading:
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Reading the diff and translating…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                case .failed(let message):
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 22))
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.system(size: 12))
                            .multilineTextAlignment(.center)
                        Button("Try Again") { app.ensureTranslated(chatID: chatID, force: true) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                case .done(let stored):
                    MessageTextView(text: stored.text, isMine: false)
                    HStack(spacing: 10) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(stored.text, forType: .string)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        Button {
                            app.ensureTranslated(chatID: chatID, force: true)
                        } label: {
                            Label("Regenerate", systemImage: "arrow.clockwise")
                        }
                        .help("Re-translate (e.g. after new commits)")
                        Spacer()
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                case nil:
                    // Key present but nothing kicked off yet (rare — chatOpened
                    // triggers it); or no key at all.
                    if app.hasAIKey {
                        Color.clear.frame(height: 1)
                            .onAppear { app.ensureTranslated(chatID: chatID) }
                    } else {
                        VStack(spacing: 8) {
                            Text("Add an AI key to auto-translate PRs")
                                .font(.system(size: 12, weight: .medium))
                            Text("Settings → AI translation")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                }

                let comments = humanComments
                if !comments.isEmpty {
                    Divider().padding(.top, 4)
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Text("Conversation")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("\(comments.count)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(comments.enumerated()), id: \.element.id) { i, message in
                            MessageBubbleRow(
                                chatID: chatID,
                                message: message,
                                showHeader: i == 0 || comments[i - 1].author.login != message.author.login,
                                isMine: message.author.login == app.me?.login,
                                isHighlighted: false,
                                isEditing: app.editingMessage == AppState.EditingTarget(chatID: chatID, messageID: message.id)
                            )
                            .equatable()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("AI summary + human comments — press the 💬 toolbar button for the full conversation, bots included.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Conversation minus the PR description (already summarized) and minus
    /// bot chatter (GitHub App accounts all carry the "[bot]" suffix).
    private var humanComments: [Message] {
        (app.transcripts[chatID] ?? []).filter {
            $0.id != "body" && !$0.author.login.hasSuffix("[bot]")
        }
    }
}

/// In-place editor swapped in for one of your bubbles (Return saves, Esc cancels).
struct MessageEditView: View {
    @EnvironmentObject var app: AppState
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("Edit message", text: $app.editDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...14)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minWidth: 300, maxWidth: 480, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.65), lineWidth: 1.5))
                .focused($focused)
                .onSubmit { Task { await app.commitEdit() } }
            HStack(spacing: 8) {
                Text("⌥↩ for a new line")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                if app.editSaving {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel") { app.cancelEdit() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
                Button("Save") { Task { await app.commitEdit() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(app.editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.editSaving)
            }
        }
        .onAppear { focused = true }
    }
}

struct BubbleContent: View {
    let message: Message
    let isMine: Bool
    var highlighted: Bool = false
    var actions: MessageMenuActions? = nil

    var body: some View {
        let text = SyncEngine.displayBody(message.body)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                AttachmentThumb(attachment: attachment)
            }
            if !text.isEmpty {
                MessageTextView(text: text, isMine: isMine, actions: actions)
            } else if message.attachments.isEmpty {
                Text("(no description)")
                    .font(.system(size: 13))
                    .italic()
                    .foregroundStyle(isMine ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(isMine ? AnyShapeStyle(bubbleBlue) : AnyShapeStyle(bubbleGray))
        )
        .overlay {
            if highlighted {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 2.5)
            }
        }
        .tint(isMine ? Color.white : bubbleLinkColor)   // links: readable on both bubble grays
        .frame(maxWidth: 480, alignment: isMine ? .trailing : .leading)
    }

    private var bubbleBlue: LinearGradient {
        LinearGradient(colors: [Color(red: 0.16, green: 0.52, blue: 1.0),
                                Color(red: 0.10, green: 0.42, blue: 0.95)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var bubbleGray: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.235, alpha: 1)
                : NSColor(calibratedRed: 0.914, green: 0.914, blue: 0.922, alpha: 1)
        })
    }
}

struct AttachmentThumb: View {
    @Environment(\.appStateRef) private var appRef
    let attachment: Attachment
    @State private var image: NSImage?

    var body: some View {
        if attachment.isImage {
            Group {
                if let image {
                    // Explicit frame: a flexible aspect-fit inside the
                    // width-hugging bubble gives layout a circular constraint.
                    let size = Self.displaySize(image)
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.primary.opacity(0.08))
                        ProgressView().controlSize(.small)
                    }
                    .frame(width: 220, height: 140)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture {
                appRef?.previewImageURL = attachment.url
            }
            .contextMenu {
                Button("Open in Browser") {
                    if let url = URL(string: attachment.url) { NSWorkspace.shared.open(url) }
                }
            }
            .help("Click to view full size")
            .task(id: attachment.url) {
                image = await ImageLoader.shared.image(for: attachment.url)
            }
        } else if let url = URL(string: attachment.url) {
            Link(destination: url) {
                Label(attachment.alt ?? "attachment", systemImage: "paperclip")
                    .font(.system(size: 12))
            }
        }
    }

    nonisolated static func displaySize(_ image: NSImage) -> CGSize {
        let w = max(image.size.width, 1)
        let h = max(image.size.height, 1)
        let scale = min(1, min(320 / w, 320 / h))
        return CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
    }
}

// MARK: - Composer

struct ComposerView: View {
    @EnvironmentObject var app: AppState
    let chatID: String
    @StateObject private var bin = AttachmentBin()
    @State private var draft = ""
    @State private var dropTargeted = false
    @State private var mentionSelection = 0
    @State private var mentionDismissed = false
    @FocusState private var focused: Bool

    private var canSend: Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || bin.hasUploads) && !bin.uploadsInFlight
    }

    // The "@prefix" being typed at the end of the draft, if any. (SwiftUI's
    // TextField doesn't expose the caret, so completion works at the tail —
    // which is where chat typing happens anyway.)
    private var mentionQuery: String? {
        guard !mentionDismissed else { return nil }
        guard let r = draft.range(of: "(?<=^|[\\s(])@([A-Za-z0-9-]{0,39})$", options: .regularExpression) else {
            return nil
        }
        return String(draft[r].dropFirst())
    }

    private var mentionMatches: [GHUserRef] {
        guard let q = mentionQuery else { return [] }
        return app.mentionCandidates(chatID: chatID, prefix: q)
    }

    var body: some View {
        let candidates = mentionMatches
        VStack(spacing: 4) {
            if !candidates.isEmpty {
                mentionStrip(candidates)
            }
            if !bin.items.isEmpty {
                AttachmentChipsView(bin: bin)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    bin.pickImages(app: app)
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 19))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 3)
                .help("Attach an image (or drag one in)")

                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...8)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                    )
                    .focused($focused)
                    .onSubmit { send() }
                    .onKeyPress(.downArrow) {
                        let count = mentionMatches.count
                        guard count > 0 else { return .ignored }
                        mentionSelection = min(mentionSelection + 1, count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !mentionMatches.isEmpty else { return .ignored }
                        mentionSelection = max(0, mentionSelection - 1)
                        return .handled
                    }
                    .onKeyPress(.tab) {
                        guard let user = selectedMention() else { return .ignored }
                        acceptMention(user)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        guard let user = selectedMention() else { return .ignored }
                        acceptMention(user)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard mentionQuery != nil else { return .ignored }
                        mentionDismissed = true
                        return .handled
                    }

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 23))
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.45))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 1)
                .disabled(!canSend)
                .help("Send (Return)")
            }
        }
        .padding(10)
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            bin.handleDrop(providers, app: app)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            // No focus grab here: ChatView is rebuilt per selection, so an
            // onAppear focus steals first responder from the sidebar list on
            // every arrow-key move. Clicking the field focuses it natively.
            draft = app.drafts[chatID] ?? ""
            bin.repoFullName = app.chats[chatID]?.repoFullName
        }
        .onChange(of: draft) { _, newValue in
            app.drafts[chatID] = newValue
            mentionDismissed = false
            mentionSelection = 0
        }
        .onChange(of: mentionQuery) { _, query in
            if query != nil, let repo = app.chats[chatID]?.repoFullName {
                app.ensureAssignables(for: repo)
            }
        }
    }

    private func selectedMention() -> GHUserRef? {
        let candidates = mentionMatches
        guard !candidates.isEmpty else { return nil }
        return candidates[min(mentionSelection, candidates.count - 1)]
    }

    private func acceptMention(_ user: GHUserRef) {
        // Mutate the LOCAL draft — the TextField binds to it; app.drafts is a
        // write-through copy that never flows back into the field.
        var text = draft
        if let r = text.range(of: "(?<=^|[\\s(])@[A-Za-z0-9-]{0,39}$", options: .regularExpression) {
            text.replaceSubrange(r, with: "@\(user.login) ")
            draft = text
        }
    }

    private func mentionStrip(_ candidates: [GHUserRef]) -> some View {
        let selected = min(mentionSelection, candidates.count - 1)
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(candidates.enumerated()), id: \.element.login) { i, user in
                Button {
                    acceptMention(user)
                } label: {
                    HStack(spacing: 7) {
                        AvatarView(user: user, size: 18)
                        Text(user.login)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(stableNameColor(user.login))
                        Spacer(minLength: 12)
                        if i == selected {
                            Text("⇥ or ↩")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4.5)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(i == selected ? Color.accentColor.opacity(0.16) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { mentionSelection = i }
                }
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        let attachments = bin.items
        bin.clear()
        // Clear the LOCAL draft — that's what the TextField shows. (onChange
        // mirrors it into app.drafts; the explicit write covers teardown races.)
        draft = ""
        app.drafts[chatID] = ""
        NSSound(named: "Pop")?.play()
        app.sendMessage(chatID: chatID, text: text, attachments: attachments)
    }
}
