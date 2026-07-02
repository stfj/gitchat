import SwiftUI
import AppKit

struct LoginView: View {
    @EnvironmentObject var app: AppState
    @State private var token = ""
    @State private var baseURL = "https://api.github.com"
    @State private var busy = false
    @State private var errorText: String?
    @State private var showAdvanced = false

    private let ghAvailable = CredentialsVault.ghInstalled

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 92, height: 92)
            Text("gitchat")
                .font(.system(size: 26, weight: .bold))
            Text("Your GitHub issues, as chats.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            VStack(spacing: 10) {
                SecureField("GitHub personal access token", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 330)
                    .onSubmit { signIn(with: token) }

                HStack {
                    Link("Create a token on GitHub…",
                         destination: URL(string: "https://github.com/settings/tokens/new?scopes=repo,read:org&description=gitchat")!)
                        .font(.system(size: 11))
                    Spacer()
                    Button(showAdvanced ? "Hide Advanced" : "Advanced") {
                        showAdvanced.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                .frame(width: 330)

                if showAdvanced {
                    TextField("API base URL (GitHub Enterprise)", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 330)
                }

                Button {
                    signIn(with: token)
                } label: {
                    Group {
                        if busy {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Sign In").frame(minWidth: 110)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || busy)

                if ghAvailable {
                    Button("Use my GitHub CLI login instead") { signInWithGh() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                        .disabled(busy)
                }

                if let errorText {
                    Text(errorText)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .frame(width: 340)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer().frame(height: 4)
            Text("The token needs the “repo” scope. It's stored only on this Mac,\nin ~/Library/Application Support/gitchat.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func signIn(with rawToken: String) {
        let tok = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tok.isEmpty else { return }
        busy = true
        errorText = nil
        Task {
            do {
                try await app.signIn(token: tok, baseURL: baseURL)
            } catch {
                errorText = error.localizedDescription
            }
            busy = false
        }
    }

    private func signInWithGh() {
        busy = true
        errorText = nil
        Task {
            let tok = await Task.detached(priority: .userInitiated) {
                CredentialsVault.detectGhToken()
            }.value
            guard let tok else {
                errorText = "Couldn't read a token from the gh CLI. Run “gh auth login” in Terminal first."
                busy = false
                return
            }
            do {
                try await app.signIn(token: tok, baseURL: "https://api.github.com")
            } catch {
                errorText = error.localizedDescription
            }
            busy = false
        }
    }
}
