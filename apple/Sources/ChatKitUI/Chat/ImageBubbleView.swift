import ChatKit
import SwiftUI

// MARK: - ImageBubbleView (macOS)
//
// Renders a `kind == "image"` IM message as an image bubble. The bytes require
// the JWT, so we fetch them via the view model (APIClient) rather than an
// AsyncImage URL, decode to NSImage, and show it. Spinner while loading,
// fallback on error.

struct ImageBubbleView: View {
    let card: ImageCard

    @Environment(AppViewModel.self) private var vm
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AppColors.border, lineWidth: 0.5))
            if let cap = card.trimmedCaption {
                Text(cap).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .task(id: card.mediaId) { await load() }
    }

    @ViewBuilder private var content: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 280, maxHeight: 360)
        } else if failed {
            placeholder(systemImage: "photo", text: "图片加载失败")
        } else {
            placeholder(systemImage: nil, text: nil).overlay(ProgressView().controlSize(.small))
        }
    }

    @ViewBuilder private func placeholder(systemImage: String?, text: String?) -> some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage) }
            if let text { Text(text).font(.system(size: 12)) }
        }
        .foregroundStyle(.secondary)
        .frame(width: 200, height: 120)
    }

    private func load() async {
        image = nil
        failed = false
        // Inline bubble shows the lightweight thumbnail (the multi-MB original is
        // only fetched when explicitly viewed).
        if let data = await vm.loadMedia(mediaId: card.mediaId, thumb: true), let ns = NSImage(data: data) {
            image = ns
        } else {
            failed = true
        }
    }
}
