import SwiftUI
import AppKit

/// Memory + URLCache-backed image loading with in-flight dedupe.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private let cache = NSCache<NSString, NSImage>()
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg)
        cache.countLimit = 500
    }

    func image(for urlString: String) async -> NSImage? {
        if let hit = cache.object(forKey: urlString as NSString) { return hit }
        if let running = inflight[urlString] { return await running.value }
        let sess = session
        let task = Task<NSImage?, Never> {
            guard let url = URL(string: urlString),
                  let (data, _) = try? await sess.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        inflight[urlString] = task
        let img = await task.value
        inflight[urlString] = nil
        if let img { cache.setObject(img, forKey: urlString as NSString) }
        return img
    }
}

struct RemoteImage<Placeholder: View>: View {
    let url: String?
    var contentMode: ContentMode = .fill
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: NSImage?

    init(url: String?, contentMode: ContentMode = .fill, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.contentMode = contentMode
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url, !url.isEmpty else { return }
            image = await ImageLoader.shared.image(for: url)
        }
    }
}

struct AvatarView: View {
    let user: GHUserRef?
    var size: CGFloat

    var body: some View {
        RemoteImage(url: user?.avatarURL) {
            ZStack {
                Circle().fill(stableAvatarColor(user?.login ?? "?"))
                Text(String((user?.login ?? "?").prefix(1)).uppercased())
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
