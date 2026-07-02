import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Account") {
                HStack {
                    AvatarView(user: app.me, size: 26)
                    Text(app.me?.login ?? "Not signed in")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("Sign Out", role: .destructive) { app.signOut() }
                        .disabled(app.phase != .ready)
                }
            }

            Section("Sync") {
                Picker("Check for new messages", selection: $app.settings.pollSeconds) {
                    Text("Every 30 seconds").tag(30.0)
                    Text("Every minute").tag(60.0)
                    Text("Every 2 minutes").tag(120.0)
                    Text("Every 5 minutes").tag(300.0)
                }
                Picker("History window", selection: $app.settings.historyDays) {
                    Text("1 week").tag(7)
                    Text("2 weeks").tag(14)
                    Text("1 month").tag(30)
                    Text("3 months").tag(90)
                }
                Toggle("Include pull requests", isOn: $app.settings.includePullRequests)
            }

            Section("Notifications") {
                Toggle("Notify about new messages", isOn: $app.settings.notificationsEnabled)
                Text("Ignored chats never notify or count toward the menu bar badge.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Image attachments") {
                TextField("Attachments repo name", text: $app.settings.assetsRepoName)
                Text("Dragged-in images are committed to github.com/\(app.me?.login ?? "you")/\(app.settings.assetsRepoName) — a public repo created on first use — so they render on GitHub too.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("App") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enable in
                        do {
                            if enable {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            app.lastErrorText = "Launch-at-login change failed: \(error.localizedDescription)"
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                LabeledContent("Data folder", value: "~/Library/Application Support/gitchat")
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
    }
}
