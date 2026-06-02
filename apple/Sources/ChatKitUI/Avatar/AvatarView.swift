import ChatKit
import SwiftUI

// `AvatarGallery` is defined in AvatarGallery.swift (auto-generated, 226 URLs).

// MARK: - Avatar image cache

/// In-memory cache of decoded avatar images so a gallery image, once fetched,
/// displays instantly on every subsequent appearance (scrolling, navigation)
/// instead of flashing the initials placeholder and re-downloading each time.
@MainActor
final class AvatarImageCache {
    static let shared = AvatarImageCache()
    private let cache = NSCache<NSURL, NSImage>()
    func image(for url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }
    func store(_ image: NSImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}

// MARK: - AvatarView

/// Rounded-square avatar with a deterministic background color and initials text.
/// Matches the WeChat-for-Mac aesthetic: 4px rounded corners, not a circle.
public struct AvatarView: View {
    let seed: String
    let title: String
    let size: CGFloat

    public init(seed: String, title: String, size: CGFloat = 38) {
        self.seed = seed
        self.title = title
        self.size = size
    }

    @State private var image: NSImage?
    @State private var failed = false

    private var bgColor: Color { AvatarHashing.color(for: seed) }
    private var letter: String { AvatarHashing.text(for: title) }
    private var fontSize: CGFloat { size * 0.42 }

    /// Deterministic avatar per seed: a fixed image from the curated gallery
    /// (matches the web client). Falls back to the colored-initials tile only
    /// when the image genuinely can't load.
    private var imageURL: URL? {
        let gallery = AvatarGallery.urls
        guard !gallery.isEmpty else { return nil }
        return URL(string: gallery[AvatarHashing.index(for: seed, count: gallery.count)])
    }

    public var body: some View {
        ZStack {
            if let image {
                // Loaded (cache hit = instant, no flash).
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if failed {
                // Genuine failure → colored-initials fallback.
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(bgColor)
                Text(letter)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(.white)
            } else {
                // Loading → neutral tile (no jarring letter→image swap).
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.gray.opacity(0.18))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .task(id: seed) { await load() }
    }

    private func load() async {
        guard let url = imageURL else { failed = true; return }
        // Cache hit → show immediately.
        if let cached = AvatarImageCache.shared.image(for: url) {
            image = cached
            return
        }
        image = nil
        failed = false
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let img = NSImage(data: data) else { failed = true; return }
            AvatarImageCache.shared.store(img, for: url)
            image = img
        } catch {
            failed = true
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("AvatarView") {
    HStack(spacing: 12) {
        AvatarView(seed: "sess-abc", title: "写 macOS 客户端", size: 38)
        AvatarView(seed: "sess-xyz", title: "回测策略", size: 38)
        AvatarView(seed: "sess-123", title: "HelloWorld", size: 38)
        AvatarView(seed: "",        title: "",            size: 38)
        AvatarView(seed: "sess-qrs", title: "疏影横斜",   size: 38)
    }
    .padding()
}
#endif
