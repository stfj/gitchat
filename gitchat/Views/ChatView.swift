import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject var app: AppState
    let chatID: String

    var body: some View {
        if let chat = app.chats[chatID] {
            VStack(spacing: 0) {
                if !chat.labels.isEmpty || !chat.assignees.isEmpty || !chat.isOpen {
                    metaBar(chat)
                    Divider()
                }
                TranscriptView(chatID: chatID)
                Divider()
                ComposerView(chatID: chatID)
            }
            .navigationTitle(chat.title)
            .navigationSubtitle("\(chat.repoFullName) #\(chat.number)")
            .toolbar { chatToolbar(chat) }
        }
    }

    @ToolbarContentBuilder
    private func chatToolbar(_ chat: Chat) -> some ToolbarContent {
        ToolbarItemGroup {
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

    private func metaBar(_ chat: Chat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if !chat.isOpen {
                    Text("Closed")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2.5)
                        .background(Capsule().fill(Color.purple))
                }
                ForEach(chat.labels, id: \.self) { LabelChip(tag: $0) }
                if !chat.assignees.isEmpty {
                    Divider().frame(height: 12)
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
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
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

    var body: some View {
        let messages = app.transcripts[chatID] ?? []
        let stillLoading = app.transcriptLoading.contains(chatID) && messages.isEmpty

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
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
                            MessageBubbleRow(chatID: chatID, message: message, showHeader: showHeader)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom-anchor")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                proxy.scrollTo("bottom-anchor", anchor: .bottom)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom-anchor", anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Bubbles

struct MessageBubbleRow: View {
    @EnvironmentObject var app: AppState
    let chatID: String
    let message: Message
    let showHeader: Bool

    private var isMine: Bool { message.author.login == app.me?.login }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMine {
                Spacer(minLength: 90)
                VStack(alignment: .trailing, spacing: 2) {
                    bubble(alignRight: true)
                    if message.failed { failedRow }
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
        BubbleContent(message: message, isMine: isMine)
            .frame(maxWidth: .infinity, alignment: alignRight ? .trailing : .leading)
            .help(Formatters.full.string(from: message.createdAt))
            .contextMenu {
                Button("Copy Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.body, forType: .string)
                }
                if let urlString = message.htmlURL, let url = URL(string: urlString) {
                    Button("Open on GitHub") { NSWorkspace.shared.open(url) }
                }
            }
    }

    private var failedRow: some View {
        Button {
            app.retryMessage(chatID: chatID, messageID: message.id)
        } label: {
            Label("Not delivered — click to retry", systemImage: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
    }
}

struct BubbleContent: View {
    let message: Message
    let isMine: Bool

    var body: some View {
        let text = SyncEngine.displayBody(message.body)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                AttachmentThumb(attachment: attachment)
            }
            if !text.isEmpty {
                MessageTextView(text: text, isMine: isMine)
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
        .tint(isMine ? Color.white : bubbleLinkColor)   // links: readable on both bubble grays
        .frame(maxWidth: 480, alignment: .leading)
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
    @EnvironmentObject var app: AppState
    let attachment: Attachment

    var body: some View {
        if attachment.isImage {
            RemoteImage(url: attachment.url, contentMode: .fit) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 220, height: 140)
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: 320, maxHeight: 320)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture {
                app.previewImageURL = attachment.url
            }
            .contextMenu {
                Button("Open in Browser") {
                    if let url = URL(string: attachment.url) { NSWorkspace.shared.open(url) }
                }
            }
            .help("Click to view full size")
        } else if let url = URL(string: attachment.url) {
            Link(destination: url) {
                Label(attachment.alt ?? "attachment", systemImage: "paperclip")
                    .font(.system(size: 12))
            }
        }
    }
}

// MARK: - Composer

struct ComposerView: View {
    @EnvironmentObject var app: AppState
    let chatID: String
    @StateObject private var bin = AttachmentBin()
    @State private var dropTargeted = false
    @State private var mentionSelection = 0
    @State private var mentionDismissed = false
    @FocusState private var focused: Bool

    private var draft: Binding<String> {
        Binding(
            get: { app.drafts[chatID] ?? "" },
            set: { app.drafts[chatID] = $0 }
        )
    }

    private var canSend: Bool {
        let hasText = !(app.drafts[chatID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || bin.hasUploads) && !bin.uploadsInFlight
    }

    // The "@prefix" being typed at the end of the draft, if any. (SwiftUI's
    // TextField doesn't expose the caret, so completion works at the tail —
    // which is where chat typing happens anyway.)
    private var mentionQuery: String? {
        guard !mentionDismissed else { return nil }
        let text = app.drafts[chatID] ?? ""
        guard let r = text.range(of: "(?<=^|[\\s(])@([A-Za-z0-9-]{0,39})$", options: .regularExpression) else {
            return nil
        }
        return String(text[r].dropFirst())
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

                TextField("Message", text: draft, axis: .vertical)
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
        .onAppear { focused = true }
        .onChange(of: app.drafts[chatID] ?? "") { _, _ in
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
        var text = app.drafts[chatID] ?? ""
        if let r = text.range(of: "(?<=^|[\\s(])@[A-Za-z0-9-]{0,39}$", options: .regularExpression) {
            text.replaceSubrange(r, with: "@\(user.login) ")
            app.drafts[chatID] = text
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
        let text = app.drafts[chatID] ?? ""
        let attachments = bin.items
        bin.clear()
        app.drafts[chatID] = ""
        NSSound(named: "Pop")?.play()
        app.sendMessage(chatID: chatID, text: text, attachments: attachments)
    }
}
