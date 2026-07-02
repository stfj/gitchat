import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var webLoginShowing = false

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
            }

            Section("AI translation (PRs)") {
                Picker("Provider", selection: $app.aiConfig.provider) {
                    Text("Anthropic (Claude)").tag("anthropic")
                    Text("OpenAI").tag("openai")
                }
                TextField("Model", text: $app.aiConfig.model,
                          prompt: Text(AITranslator.defaultModel(provider: app.aiConfig.provider)))
                SecureField("API key", text: $app.aiConfig.key)
                Text("Powers the ✨ Translate button on pull requests — explains the change in plain, non-engineer language. The key is stored locally and only sent to the provider you pick.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Notify about new messages", isOn: $app.settings.notificationsEnabled)
                Text("Ignored chats never notify or count toward the menu bar badge.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Image attachments") {
                Toggle("Upload privately to GitHub's attachment storage", isOn: $app.settings.privateAttachments)
                if app.settings.privateAttachments {
                    HStack {
                        Image(systemName: app.webSessionActive ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
                            .foregroundStyle(app.webSessionActive ? Color.green : Color.secondary)
                        Text(app.webSessionActive ? "GitHub web session active" : "Needs a one-time GitHub sign-in")
                            .font(.system(size: 12))
                        Spacer()
                        if app.webSessionActive {
                            Button("Sign Out") {
                                Task {
                                    await WebSession.shared.signOut()
                                    app.webSessionActive = false
                                }
                            }
                        } else {
                            Button("Sign In…") { webLoginShowing = true }
                        }
                    }
                    Text("Images land at github.com/user-attachments — the same place the GitHub website puts them — and stay as private as the repo they're posted to.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Attachments repo name", text: $app.settings.assetsRepoName)
                    Text("Legacy mode: images are committed to github.com/\(app.me?.login ?? "you")/\(app.settings.assetsRepoName) — a PUBLIC repo created on first use.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
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
        .frame(width: 480, height: 600)
        .sheet(isPresented: $webLoginShowing) {
            GitHubLoginSheet().environmentObject(app)
        }
    }
}
