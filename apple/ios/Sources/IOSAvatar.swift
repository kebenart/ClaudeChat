import SwiftUI
import ChatKit

/// In-memory cache so a gallery image, once fetched, shows instantly on every
/// later appearance instead of re-downloading + flashing the placeholder.
@MainActor
final class IOSAvatarImageCache {
    static let shared = IOSAvatarImageCache()
    private let cache = NSCache<NSURL, UIImage>()
    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func store(_ image: UIImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }

    /// Warm the cache for a batch of seeds off the main thread so the first
    /// scroll of a freshly-synced list doesn't fire ~150 network fetches inline.
    func prefetch(seeds: [String]) {
        let urls = seeds.compactMap { URL(string: AvatarGallery.url(for: $0)) }
            .filter { cache.object(forKey: $0 as NSURL) == nil }
        guard !urls.isEmpty else { return }
        Task.detached(priority: .utility) {
            await withTaskGroup(of: (URL, UIImage?).self) { group in
                for url in urls {
                    group.addTask {
                        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return (url, nil) }
                        return (url, UIImage(data: data))
                    }
                }
                for await (url, img) in group {
                    if let img { await IOSAvatarImageCache.shared.store(img, for: url) }
                }
            }
        }
    }
}

/// Deterministic gallery avatar for iOS (matches the web + macOS clients): a
/// seed (conversation id) maps to a fixed cute/anime image from `AvatarGallery`.
/// Cached so it doesn't re-flash; neutral placeholder while loading, initials
/// only on genuine failure.
struct IOSAvatar: View {
    let seed: String
    let title: String
    var size: CGFloat = 44

    @State private var image: UIImage?
    @State private var failed = false

    init(seed: String, title: String, size: CGFloat = 44) {
        self.seed = seed
        self.title = title
        self.size = size
        // Render a cached avatar IMMEDIATELY (the common case after first load)
        // instead of flashing the placeholder and waiting a `.task` cycle — that
        // per-cell async hop was a chunk of the list/chat scroll jank.
        if let url = URL(string: AvatarGallery.url(for: seed)),
           let cached = IOSAvatarImageCache.shared.image(for: url) {
            _image = State(initialValue: cached)
        }
    }

    private var url: URL? { URL(string: AvatarGallery.url(for: seed)) }
    private var letter: String { String((title.isEmpty ? "?" : title).prefix(1)) }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if failed {
                RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.7))
                Text(letter)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.18))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: seed) { if image == nil { await load() } }
    }

    private func load() async {
        guard let url else { failed = true; return }
        if let cached = IOSAvatarImageCache.shared.image(for: url) { image = cached; return }
        image = nil; failed = false
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let img = UIImage(data: data) else { failed = true; return }
            IOSAvatarImageCache.shared.store(img, for: url)
            image = img
        } catch {
            failed = true
        }
    }
}
