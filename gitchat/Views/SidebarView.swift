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
                    Toggle("Show Closed Issues", isOn: $app.settings.showClosed)
                    Toggle("Include Pull Requests", isOn: $app.settings.includePullRequests)
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
        HStack {
            Text(app.filter == .all ? "Chats" : app.filter.rawValue)
                .font(.system(size: 20, weight: .bold))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
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

    private var chatList: some View {
        let rows = app.rows()
        let pinned = app.pinnedChats()
        let showPinned = !isSearching && app.filter == .all && !pinned.isEmpty

        return List(selection: $app.selectedChatID) {
            if showPinned {
                Section {
                    PinnedGridView(chats: pinned)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 8, trailing: 6))
                }
            }
            Section {
                ForEach(rows) { row in
                    ChatRowView(row: row)
                        .tag(row.chat.id as String?)
                        .contextMenu { ChatContextMenu(chat: row.chat).environmentObject(app) }
                }
            }
            if rows.isEmpty && !showPinned {
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

// MARK: - Pinned grid (Messages-style circles up top)

struct PinnedGridView: View {
    @EnvironmentObject var app: AppState
    let chats: [Chat]

    private let columns = [GridItem(.adaptive(minimum: 74), spacing: 4)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(chats) { chat in
                VStack(spacing: 3) {
                    ZStack(alignment: .topTrailing) {
                        AvatarView(user: chat.lastMessageAuthor ?? chat.author, size: 52)
                            .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1))
                        if chat.unreadCount > 0 {
                            Text("\(chat.unreadCount)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.blue))
                                .offset(x: 7, y: -3)
                        }
                    }
                    Text(chat.title)
                        .font(.system(size: 10.5, weight: chat.unreadCount > 0 ? .semibold : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: 78)
                    Text(chat.repoFullName.components(separatedBy: "/").last ?? "")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .onTapGesture { app.selectedChatID = chat.id }
                .contextMenu { ChatContextMenu(chat: chat).environmentObject(app) }
            }
        }
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
                    StateDot(isOpen: chat.isOpen)
                    Text("\(chat.repoFullName) #\(chat.number)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if chat.isPullRequest {
                        Text("PR")
                            .font(.system(size: 8.5, weight: .bold))
                            .padding(.horizontal, 3).padding(.vertical, 0.5)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.18)))
                    }
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
        if let match = row.matchSnippet { return match }
        let mine = chat.lastMessageAuthor?.login == app.me?.login
        return (mine ? "You: " : "") + previewSnippet(chat.lastMessageSnippet)
    }
}
