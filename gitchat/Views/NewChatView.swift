import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NewChatView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var repo: RepoInfo?
    @State private var title = ""
    @State private var issueBody = ""
    @State private var repoLabels: [GHLabel] = []
    @State private var repoAssignees: [GHUser] = []
    @State private var pickedLabels: Set<String> = []
    @State private var pickedAssignees: Set<String> = []
    @State private var creating = false
    @State private var dropTargeted = false
    @StateObject private var bin = AttachmentBin()

    private var canCreate: Bool {
        repo != nil
            && !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !creating
            && !bin.uploadsInFlight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Issue")
                .font(.system(size: 16, weight: .semibold))

            RepoPicker(selection: $repo)

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))

            ZStack(alignment: .topLeading) {
                TextEditor(text: $issueBody)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 130, maxHeight: 220)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(dropTargeted ? Color.accentColor : Color.primary.opacity(0.15),
                                    lineWidth: dropTargeted ? 2 : 1)
                    )
                if issueBody.isEmpty {
                    Text("Describe the issue… (drag images here)")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
                bin.handleDrop(providers, app: app)
            }

            if !bin.items.isEmpty {
                AttachmentChipsView(bin: bin)
            }

            if repo != nil {
                if !repoLabels.isEmpty { labelsSection }
                if !repoAssignees.isEmpty { assigneesSection }
            }

            HStack {
                Button {
                    bin.pickImages(app: app)
                } label: {
                    Label("Attach Images", systemImage: "photo.badge.plus")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(creating ? "Creating…" : "Create Issue") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(18)
        .frame(width: 580)
        .onChange(of: repo?.fullName) { _, newValue in
            pickedLabels = []
            pickedAssignees = []
            repoLabels = []
            repoAssignees = []
            guard let newValue else { return }
            Task {
                let meta = await app.fetchRepoMeta(newValue)
                if repo?.fullName == newValue {
                    repoLabels = meta.labels
                    repoAssignees = meta.assignees
                }
            }
        }
    }

    private var labelsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("LABELS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(repoLabels, id: \.name) { label in
                        let picked = pickedLabels.contains(label.name)
                        Button {
                            if picked { pickedLabels.remove(label.name) }
                            else { pickedLabels.insert(label.name) }
                        } label: {
                            HStack(spacing: 3) {
                                if picked { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
                                Text(label.name).font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(Capsule().fill(Color(hexLabel: label.color ?? "8b949e")
                                .opacity(picked ? 0.45 : 0.15)))
                            .overlay(Capsule().stroke(Color(hexLabel: label.color ?? "8b949e")
                                .opacity(picked ? 0.9 : 0.4), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private var assigneesSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("ASSIGNEES")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(repoAssignees, id: \.login) { user in
                        let picked = pickedAssignees.contains(user.login)
                        Button {
                            if picked { pickedAssignees.remove(user.login) }
                            else { pickedAssignees.insert(user.login) }
                        } label: {
                            HStack(spacing: 4) {
                                AvatarView(user: user.ref, size: 16)
                                Text(user.login).font(.system(size: 11))
                                if picked { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(picked ? Color.accentColor.opacity(0.25)
                                                              : Color.primary.opacity(0.06)))
                            .overlay(Capsule().stroke(picked ? Color.accentColor : Color.clear, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func create() {
        guard let repo else { return }
        creating = true
        var body = issueBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = bin.markdownForUploads()
        if !images.isEmpty {
            body += (body.isEmpty ? "" : "\n\n") + images
        }
        let repoName = repo.fullName
        let issueTitle = title.trimmingCharacters(in: .whitespaces)
        let labels = Array(pickedLabels)
        let assignees = Array(pickedAssignees)
        Task {
            do {
                try await app.createIssue(repo: repoName, title: issueTitle, body: body,
                                          labels: labels, assignees: assignees)
                dismiss()
            } catch {
                app.lastErrorText = "Couldn't create the issue: \(error.localizedDescription)"
            }
            creating = false
        }
    }
}

// MARK: - Repo picker (searchable popover, most recently chatty first)

struct RepoPicker: View {
    @EnvironmentObject var app: AppState
    @Binding var selection: RepoInfo?
    @State private var open = false
    @State private var query = ""

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 6) {
                if let repo = selection {
                    RemoteImage(url: repo.ownerAvatarURL) {
                        Color.secondary.opacity(0.25)
                    }
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3.5))
                    Text(repo.fullName).font(.system(size: 12.5))
                    if repo.isPrivate {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text("Choose a repository…").font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                TextField("Filter repositories", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .padding(8)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { repo in
                            Button {
                                selection = repo
                                open = false
                            } label: {
                                HStack(spacing: 7) {
                                    RemoteImage(url: repo.ownerAvatarURL) {
                                        Color.secondary.opacity(0.25)
                                    }
                                    .frame(width: 18, height: 18)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    Text(repo.fullName).font(.system(size: 12.5))
                                    Spacer()
                                    if repo.isPrivate {
                                        Image(systemName: "lock.fill")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(selection?.fullName == repo.fullName
                                        ? Color.accentColor.opacity(0.14) : Color.clear)
                        }
                        if filtered.isEmpty {
                            Text(app.repos.isEmpty ? "Repositories are still syncing…" : "No matches")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(14)
                        }
                    }
                }
                .frame(width: 400, height: 300)
            }
        }
    }

    private var filtered: [RepoInfo] {
        let base = app.repoChoices()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? base : base.filter { $0.fullName.lowercased().contains(q) }
    }
}
