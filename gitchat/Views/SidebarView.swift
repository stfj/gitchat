import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var app: AppState
    @FocusState private var searchFocused: Bool

    private var isSearching: Bool {
        !app.searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 8)
            chatList
            Divider()
            footer
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Filter", selection: $app.filter) {
                        ForEach(ChatFilter.allCases) { f in
                            Label(f.rawValue, systemImage: f.symbol).tag(f)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle("Show Closed", isOn: $app.settings.showClosed)
                    Button("Mark All as Read") { app.markAllRead() }
                } label: {
                    Image(systemName: app.filter == .all
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
                .help("Filter chats")
            }
            ToolbarItem {
                Button {
                    app.composeVisible = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New issue (⌘N)")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gcFocusSearch)) { _ in
            searchFocused = true
        }
    }

    private var header: some View {
        Picker("Tab", selection: $app.sidebarTab) {
            ForEach(SidebarTab.allCases) { tab in
                Text(tabLabel(tab)).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    private func tabLabel(_ tab: SidebarTab) -> String {
        let unread = app.unreadCount(for: tab)
        let name: String = switch tab {
        case .issues: "Issues"
        case .prs: "PRs"
        case .mine: "Me"
        }
        return unread > 0 ? "\(name) • \(unread)" : name
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Search", text: $app.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if isSearching {
                Button {
                    app.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }

    @ViewBuilder private var chatList: some View {
        if isSearching {
            searchList
        } else {
            normalList
        }
    }

    private var normalList: some View {
        let rows = app.rows()
        let pinned = app.filter == .all ? app.pinnedChats() : []

        return List(selection: $app.selectedChatID) {
            if !pinned.isEmpty {
                Section {
                    ForEach(pinned) { chat in
                        ChatRowView(row: ChatRowModel(chat: chat))
                            .tag(chat.id as String?)
                            .contextMenu { ChatContextMenu(chat: chat).environmentObject(app) }
                    }
                    // Slight split between pinned chats and the rest.
                    Divider()
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 3, trailing: 10))
                }
            }
            Section {
                ForEach(rows) { row in
                    ChatRowView(row: row)
                        .tag(row.chat.id as String?)
                        .contextMenu { ChatContextMenu(chat: row.chat).environmentObject(app) }
                }
            }
            if rows.isEmpty && pinned.isEmpty {
                emptyState
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.sidebar)
        // Separate list identity per tab — sharing one list makes the tabs
        // share (and slowly drift) a single scroll offset when toggling.
        .id(app.sidebarTab)
    }

    private var searchList: some View {
        let results = app.searchResults(app.searchText)
        return List(selection: $app.selectedChatID) {
            if !results.chats.isEmpty {
                Section("Chats") {
                    ForEach(results.chats) { row in
                        ChatRowView(row: row)
                            .tag(row.chat.id as String?)
                            .contextMenu { ChatContextMenu(chat: row.chat).environmentObject(app) }
                    }
                }
            }
            if !results.messages.isEmpty {
                Section("Messages") {
                    ForEach(results.messages) { hit in
                        MessageHitRow(hit: hit, query: app.searchText)
                            .contentShape(Rectangle())
                            .onTapGesture { app.open(hit: hit) }
                    }
                }
            }
            if results.chats.isEmpty && results.messages.isEmpty {
                emptyState
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 6) {
            if isSearching {
                Text("No matches")
                    .font(.system(size: 13, weight: .medium))
                Text("Try a different search.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if app.chats.isEmpty {
                ProgressView().controlSize(.small).padding(.bottom, 2)
                Text("Fetching your issues…")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text("Nothing here")
                    .font(.system(size: 13, weight: .medium))
                Text(app.filter == .ignored ? "You haven't ignored any chats." : "You're all caught up.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if app.syncStatusText.hasPrefix("Syncing") {
                ProgressView().controlSize(.mini)
            }
            Text(app.syncStatusText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            AvatarView(user: app.me, size: 15)
            Text(app.me?.login ?? "")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

// MARK: - Row

struct ChatRowView: View {
    @EnvironmentObject var app: AppState
    let row: ChatRowModel

    private var chat: Chat { row.chat }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.blue)
                .frame(width: 8, height: 8)
                .opacity(chat.unreadCount > 0 && !chat.ignored ? 1 : 0)
            AvatarView(user: chat.lastMessageAuthor ?? chat.author, size: 42)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if chat.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    Text(chat.title)
                        .font(.system(size: 13, weight: chat.unreadCount > 0 ? .semibold : .regular))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Text(chat.lastMessageAt.chatStamp)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    StateDot(isOpen: chat.isOpen, merged: chat.prMerged ?? !chat.isPullRequest)
                    Text("\(chat.repoFullName) #\(chat.number)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if chat.ignored {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(snippetLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 3)
        .opacity(chat.ignored ? 0.6 : 1)
    }

    private var snippetLine: String {
        let mine = chat.lastMessageAuthor?.login == app.me?.login
        return (mine ? "You: " : "") + previewSnippet(chat.lastMessageSnippet)
    }
}

// MARK: - Full-text search result row

struct MessageHitRow: View {
    let hit: MessageHit
    let query: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AvatarView(user: hit.author, size: 30)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1.5) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(hit.chatTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(hit.createdAt.chatStamp)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Text(hit.repoLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(highlightedSnippet)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 3)
        .help("Jump to this message")
    }

    private var highlightedSnippet: AttributedString {
        let full = "\(hit.author.login): \(hit.snippet)"
        var attr = AttributedString(full)
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty,
           let r = full.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            let startOffset = full.distance(from: full.startIndex, to: r.lowerBound)
            let length = full.distance(from: r.lowerBound, to: r.upperBound)
            let s = attr.index(attr.startIndex, offsetByCharacters: startOffset)
            let e = attr.index(s, offsetByCharacters: length)
            attr[s..<e].inlinePresentationIntent = .stronglyEmphasized
            attr[s..<e].foregroundColor = .primary
        }
        return attr
    }
}
