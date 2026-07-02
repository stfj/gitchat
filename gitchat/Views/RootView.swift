import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Group {
            switch app.phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loggedOut:
                LoginView()
            case .ready:
                MainSplitView()
            }
        }
        .frame(minWidth: 820, minHeight: 480)
        .overlay {
            if let url = app.previewImageURL {
                ImageLightboxView(url: url) { app.previewImageURL = nil }
                    .transition(.opacity.combined(with: .scale(scale: 1.03)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: app.previewImageURL)
        .alert("gitchat", isPresented: errorShowing) {
            Button("OK") { app.lastErrorText = nil }
        } message: {
            Text(app.lastErrorText ?? "")
        }
        .sheet(isPresented: $app.composeVisible) {
            NewChatView().environmentObject(app)
        }
        // When the compose sheet is up, its own login sheet handles this instead
        // (only one sheet can hang off the root at a time).
        .sheet(isPresented: Binding(
            get: { app.webLoginVisible && !app.composeVisible },
            set: { if !$0 { app.webLoginVisible = false } }
        )) {
            GitHubLoginSheet().environmentObject(app)
        }
    }

    private var errorShowing: Binding<Bool> {
        Binding(
            get: { app.lastErrorText != nil },
            set: { if !$0 { app.lastErrorText = nil } }
        )
    }
}

struct MainSplitView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 290, ideal: 340, max: 440)
        } detail: {
            if let id = app.selectedChatID, app.chats[id] != nil {
                ChatView(chatID: id)
                    .id(id)
            } else {
                ContentUnavailableView {
                    Label("No Chat Selected", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Pick a conversation from the list, or press ⌘N to start a new issue.")
                }
            }
        }
    }
}
