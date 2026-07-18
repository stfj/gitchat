import SwiftUI
import AppKit
import ImageIO

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
        // Byte budget matters more than entry count: full-res lightbox decodes
        // run tens of MB each, and NSCache without costs let two weeks of
        // browsing pin gigabytes of bitmaps (the long-uptime slowdown).
        cache.totalCostLimit = 192 << 20
    }

    private nonisolated static func cost(of image: NSImage) -> Int {
        if let rep = image.representations.first as? NSBitmapImageRep {
            return rep.pixelsWide * rep.pixelsHigh * 4
        }
        // Our decodes report points at half pixel size → ×4 area ×4 bytes.
        return Int(image.size.width * image.size.height * 16)
    }

    /// maxPixel: decode target for the largest dimension (screenshots are often
    /// 4000px wide but display at ~320pt — drawing full-size bitmaps during
    /// scroll was a big part of transcript chunkiness). nil = full resolution.
    func image(for urlString: String, maxPixel: CGFloat? = 900) async -> NSImage? {
        let cacheKey = (maxPixel == nil ? "full|" : "thumb|") + urlString
        if let hit = cache.object(forKey: cacheKey as NSString) { return hit }
        if let running = inflight[cacheKey] { return await running.value }
        let sess = session
        // Private user-attachments are session-gated; ride the in-app web login.
        let needsCookies = urlString.hasPrefix("https://github.com/user-attachments")
        let task = Task<NSImage?, Never> {
            guard let url = URL(string: urlString) else { return nil }
            var request = URLRequest(url: url)
            if needsCookies, let header = await WebSession.shared.cookieHeader() {
                request.setValue(header, forHTTPHeaderField: "Cookie")
                request.setValue(WebSession.userAgent, forHTTPHeaderField: "User-Agent")
            }
            guard let (data, _) = try? await sess.data(for: request) else { return nil }
            if let maxPixel, let small = Self.downsampled(data: data, maxPixel: maxPixel) {
                return small
            }
            return NSImage(data: data)
        }
        inflight[cacheKey] = task
        let img = await task.value
        inflight[cacheKey] = nil
        if let img { cache.setObject(img, forKey: cacheKey as NSString, cost: Self.cost(of: img)) }
        return img
    }

    nonisolated static func downsampled(data: Data, maxPixel: CGFloat) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as [CFString: Any] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }
        // Report points at 2x so retina displays stay crisp.
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
    }

    /// Test probe: is a thumb entry currently resident?
    func cached(for urlString: String) -> Bool {
        cache.object(forKey: ("thumb|" + urlString) as NSString) != nil
    }

    /// Seed the cache (e.g. show the just-uploaded local image under its final URL).
    func prime(_ image: NSImage, for urlString: String) {
        let cost = Self.cost(of: image)
        cache.setObject(image, forKey: ("thumb|" + urlString) as NSString, cost: cost)
        cache.setObject(image, forKey: ("full|" + urlString) as NSString, cost: cost)
    }
}

struct RemoteImage<Placeholder: View>: View {
    let url: String?
    var contentMode: ContentMode = .fill
    var maxPixel: CGFloat? = 900
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: NSImage?

    init(url: String?, contentMode: ContentMode = .fill, maxPixel: CGFloat? = 900,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.contentMode = contentMode
        self.maxPixel = maxPixel
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
            image = await ImageLoader.shared.image(for: url, maxPixel: maxPixel)
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
