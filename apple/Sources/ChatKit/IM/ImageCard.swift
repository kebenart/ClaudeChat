import Foundation

// MARK: - ImageCard
//
// An assistant-sent image that arrives as a normal IM message with
// `kind == "image"`. Its `content` is a small JSON `{ mediaId, caption }`. The
// bytes are fetched separately from `GET /api/im/media/:mediaId` (auth'd). The
// media id is `<32 hex>.<ext>` — the only shape the server will serve.

public struct ImageCard: Sendable, Decodable, Hashable {
    public let mediaId: String
    public let caption: String?
    /// Original (full-res) byte size, for the "查看原图 (N MB)" affordance.
    public let bytes: Int?

    public init(mediaId: String, caption: String? = nil, bytes: Int? = nil) {
        self.mediaId = mediaId
        self.caption = caption
        self.bytes = bytes
    }

    /// Human-readable original size, e.g. "2.4 MB" / "820 KB". nil when unknown.
    public var sizeLabel: String? {
        guard let bytes, bytes > 0 else { return nil }
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        }
        return "\(max(1, bytes / 1024)) KB"
    }

    /// Decode an image message's `content` JSON. Returns nil when the string
    /// isn't valid image JSON or the media id isn't the expected shape, so
    /// callers fall back to a plain text bubble.
    public static func parse(_ content: String) -> ImageCard? {
        guard let data = content.data(using: .utf8) else { return nil }
        guard let card = try? JSONDecoder().decode(ImageCard.self, from: data) else { return nil }
        guard
            card.mediaId.range(
                of: "^[0-9a-f]{32}\\.(png|jpe?g|gif|webp)$",
                options: .regularExpression
            ) != nil
        else { return nil }
        return card
    }

    public var trimmedCaption: String? {
        guard let c = caption?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty else { return nil }
        return c
    }
}
