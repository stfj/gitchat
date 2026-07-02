import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Attachment intake (shared by the composer and the new-issue sheet)

@MainActor
final class AttachmentBin: ObservableObject {
    @Published var items: [PendingAttachment] = []

    /// Target repo for uploads (GitHub's attachment host scopes assets to a repo).
    var repoFullName: String?

    var uploadsInFlight: Bool {
        items.contains { if case .uploading = $0.state { true } else { false } }
    }
    var hasUploads: Bool {
        items.contains { if case .uploaded = $0.state { true } else { false } }
    }

    func markdownForUploads() -> String {
        items.compactMap { item in
            if case .uploaded(let url) = item.state { return "![\(item.fileName)](\(url))" }
            return nil
        }.joined(separator: "\n")
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    func clear() {
        items = []
    }

    nonisolated static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]

    func ingest(url: URL, app: AppState) {
        guard Self.imageExtensions.contains(url.pathExtension.lowercased()) else {
            app.lastErrorText = "Only image files can be attached."
            return
        }
        guard let data = try? Data(contentsOf: url) else { return }
        ingest(data: data, name: url.lastPathComponent, app: app)
    }

    func ingest(data: Data, name: String, app: AppState) {
        guard data.count <= 25_000_000 else {
            app.lastErrorText = "That image is too large (25 MB max)."
            return
        }
        let attachment = PendingAttachment(fileName: name, thumbnail: NSImage(data: data), state: .uploading)
        items.append(attachment)
        let id = attachment.id
        let repo = repoFullName
        Task {
            do {
                let url = try await app.upload(data: data, fileName: name, repoFullName: repo)
                if let i = self.items.firstIndex(where: { $0.id == id }) {
                    self.items[i].state = .uploaded(url)
                    // Private attachment URLs need a web session to fetch; show
                    // the local image instantly instead.
                    if let thumb = self.items[i].thumbnail {
                        ImageLoader.shared.prime(thumb, for: url)
                    }
                }
            } catch {
                if let i = self.items.firstIndex(where: { $0.id == id }) {
                    self.items[i].state = .failed
                }
                app.lastErrorText = "Image upload failed: \(error.localizedDescription)"
            }
        }
    }

    func handleDrop(_ providers: [NSItemProvider], app: AppState) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var fileURL: URL?
                    if let data = item as? Data {
                        fileURL = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let u = item as? URL {
                        fileURL = u
                    }
                    guard let fileURL else { return }
                    Task { @MainActor in self.ingest(url: fileURL, app: app) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in self.ingest(data: data, name: "image.png", app: app) }
                }
            }
        }
        return handled
    }

    func pickImages(app: AppState) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .heic, .tiff, .webP, .bmp]
        panel.allowsMultipleSelection = true
        panel.message = "Choose images to attach"
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                for u in urls { self.ingest(url: u, app: app) }
            }
        }
    }
}

struct AttachmentChipsView: View {
    @ObservedObject var bin: AttachmentBin

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(bin.items) { item in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let thumb = item.thumbnail {
                                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Image(systemName: "photo").font(.system(size: 20)).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay {
                            switch item.state {
                            case .uploading:
                                ZStack {
                                    RoundedRectangle(cornerRadius: 9).fill(.black.opacity(0.45))
                                    ProgressView().controlSize(.small)
                                }
                            case .failed:
                                ZStack {
                                    RoundedRectangle(cornerRadius: 9).fill(.black.opacity(0.45))
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                                }
                            case .uploaded:
                                RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.12), lineWidth: 1)
                            }
                        }
                        Button {
                            bin.remove(item.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white, .gray)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .help("Remove attachment")
                    }
                    .padding(.top, 5)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 66)
    }
}

// MARK: - Image lightbox (in-window full-size image viewer)

struct ImageLightboxView: View {
    let url: String
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.88)
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            RemoteImage(url: url, contentMode: .fit, maxPixel: nil) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)   // clicks anywhere fall through to the backdrop and close

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.95), .white.opacity(0.22))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)   // Esc closes too
            .padding(14)
            .help("Close (Esc)")
        }
    }
}

// MARK: - Small shared views

struct DaySeparator: View {
    let label: String
    var body: some View {
        HStack {
            Spacer()
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

struct LabelChip: View {
    let tag: LabelTag
    var body: some View {
        Text(tag.name)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(Color(hexLabel: tag.colorHex).opacity(0.22)))
            .overlay(Capsule().stroke(Color(hexLabel: tag.colorHex).opacity(0.55), lineWidth: 1))
    }
}

struct StateDot: View {
    let isOpen: Bool
    var body: some View {
        Circle()
            .fill(isOpen ? Color.green : Color.purple)
            .frame(width: 5, height: 5)
    }
}

struct ChatContextMenu: View {
    @EnvironmentObject var app: AppState
    let chat: Chat

    var body: some View {
        Button(chat.pinned ? "Unpin" : "Pin") { app.togglePin(chat.id) }
        Button(chat.ignored ? "Stop Ignoring" : "Ignore") { app.toggleIgnore(chat.id) }
        if chat.unreadCount > 0 {
            Button("Mark as Read") { app.markRead(chat.id) }
        } else {
            Button("Mark as Unread") { app.markUnread(chat.id) }
        }
        Divider()
        Button("Open in Safari") { app.openInSafari(chat.id) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(chat.htmlURL, forType: .string)
        }
        Divider()
        Button(chat.isOpen ? "Close Issue" : "Reopen Issue") { app.toggleClosed(chat.id) }
    }
}
