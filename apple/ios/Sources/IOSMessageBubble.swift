import SwiftUI
import ChatKit
import UIKit

// MARK: - IOSMessageBubble
//
// One chat bubble. Assistant content renders full markdown (MarkdownText);
// user content stays plain. Long messages collapse to a capped height with a
// 展开全文 / 收起 toggle so a wall of text doesn't dominate the thread.

struct IOSMessageBubble: View {
    let message: ImMessageDTO
    let conversation: ImConversationDTO
    /// True for an optimistic outgoing bubble whose send failed — shows a red "!"
    /// that taps to resend.
    var isFailed: Bool = false
    var onResend: () -> Void = {}
    /// Open the choice poll — handled by ChatDetailView (a stable parent) so the
    /// sheet survives message-list reloads.
    var onOpenChoice: (ChoiceCard) -> Void = { _ in }

    @Environment(IOSAppModel.self) private var model
    @State private var showFull = false
    @State private var showResend = false
    /// Lazily-fetched full body for a server-truncated message. nil until loaded.
    @State private var fullContent: String?
    @State private var loadingFull = false

    private var isUser: Bool { message.role == "user" }

    /// A `kind == "choice"` message renders as an interactive 红包-style card.
    private var choiceCard: ChoiceCard? {
        message.kind == "choice" ? ChoiceCard.parse(message.content) : nil
    }

    /// A `kind == "image"` message renders as an image bubble.
    private var imageCard: ImageCard? {
        message.kind == "image" ? ImageCard.parse(message.content) : nil
    }

    /// Heuristic: collapse very long bubbles by default. Also folds when the
    /// server already truncated the message (content is just a preview), and
    /// whenever the body contains a fenced code block — an un-folded code block
    /// (its horizontal ScrollView has unbounded width) inside a height-unbounded
    /// bubble made SwiftUI's layout solver spin forever and froze the whole app.
    /// Folding caps the height (260), which constrains that ScrollView.
    private var foldable: Bool {
        message.isTruncated ||
        message.content.count > 500 ||
        message.content.filter { $0 == "\n" }.count > 14 ||
        message.content.contains("```")
    }

    /// What the full-text sheet shows: the lazily-fetched full body for a
    /// truncated message (once loaded), else the already-loaded content.
    private var sheetContent: String { fullContent ?? message.content }

    /// Open the full-text sheet; for a server-truncated message kick off the
    /// lazy fetch of the full body (best-effort — falls back to the preview).
    private func openFull() {
        showFull = true
        guard message.isTruncated, fullContent == nil, !loadingFull else { return }
        loadingFull = true
        Task {
            let body = await model.fetchMessageContent(
                conversationId: message.conversationId, messageId: message.id)
            if let body { fullContent = body }
            loadingFull = false
        }
    }

    var body: some View {
        if let card = choiceCard {
            choiceRow(card)
        } else if let img = imageCard {
            imageRow(img)
        } else {
            standardBody
        }
    }

    /// An image card laid out like an assistant (left-aligned) bubble.
    private func imageRow(_ card: ImageCard) -> some View {
        HStack(alignment: .top, spacing: 8) {
            IOSAvatar(seed: conversation.id, title: conversation.title ?? "C", size: 32)
            IOSImageBubble(card: card)
                .environment(model)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A choice card laid out like an assistant (left-aligned) bubble.
    private func choiceRow(_ card: ChoiceCard) -> some View {
        HStack(alignment: .top, spacing: 8) {
            IOSAvatar(seed: conversation.id, title: conversation.title ?? "C", size: 32)
            IOSChoiceCardView(card: card, conversationId: message.conversationId, onOpen: onOpenChoice)
                .environment(model)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var standardBody: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 8) {
                if isUser {
                    Spacer(minLength: 40)
                    if isFailed {
                        Button { showResend = true } label: {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 19)).foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 6)
                    }
                } else {
                    IOSAvatar(seed: conversation.id, title: conversation.title ?? "C", size: 32)
                }
                bubbleBody
                if isUser {
                    IOSAvatar(seed: model.myAvatarSeed, title: model.myDisplayName, size: 32)
                } else {
                    Spacer(minLength: 40)
                }
            }
            .confirmationDialog("重新发送这条消息?", isPresented: $showResend, titleVisibility: .visible) {
                Button("重新发送") { onResend() }
                Button("取消", role: .cancel) {}
            }
            if let trace = message.toolTrace, trace.count > 0 {
                ToolTraceCard(conversationId: message.conversationId, trace: trace, alignTrailing: isUser)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    @ViewBuilder private var bubbleBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
                .frame(maxHeight: foldable ? 260 : nil, alignment: .top)
                .clipped()
            if foldable {
                Button { openFull() } label: {
                    Text("展开全文")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isUser ? WC.bubbleOutText.opacity(0.8) : WC.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(isUser ? WC.bubbleOut : WC.bubbleIn)
        .foregroundStyle(isUser ? WC.bubbleOutText : WC.bubbleInText)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.05), radius: 1, y: 0.5)
        .contextMenu {
            Button {
                UIPasteboard.general.string = message.content
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            Button {
                openFull()
            } label: {
                Label("查看全文", systemImage: "doc.richtext")
            }
        }
        .sheet(isPresented: $showFull) {
            MarkdownSheet(title: isUser ? "我的消息" : "完整内容",
                          content: sheetContent, loading: loadingFull)
        }
    }

    @ViewBuilder private var content: some View {
        if isUser {
            Text(message.content).textSelection(.enabled)
        } else {
            MarkdownText(content: message.content)
        }
    }
}

// MARK: - ToolTraceCard
//
// Inline, non-interactive count of a turn's tool activity: a gray pill
// "执行了 N 个操作". Just the count — no expansion, no detail. Mirrors the web
// WeChatToolCard collapsed pill.

private struct ToolTraceCard: View {
    let conversationId: String
    let trace: ImToolTrace
    let alignTrailing: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 11))
                .foregroundStyle(WC.accent)
            Text("执行了 \(trace.count) 个操作")
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .frame(maxWidth: .infinity, alignment: alignTrailing ? .trailing : .leading)
    }
}


// MARK: - IOSChoiceCardView
//
// Renders a `kind == "choice"` IM message as a compact 红包-style interactive
// card. Tapping a pending card opens IOSChoicePollSheet (a vote-like selection);
// an answered card renders dimmed with the result summary and isn't tappable.

struct IOSChoiceCardView: View {
    let card: ChoiceCard
    let conversationId: String
    /// Ask the stable parent (ChatDetailView) to present the poll sheet.
    var onOpen: (ChoiceCard) -> Void = { _ in }

    @Environment(IOSAppModel.self) private var model

    private var accent: Color { WC.accent }   // WeChat green
    private var icon: String { card.isExitPlanMode ? "checklist" : "questionmark.bubble.fill" }
    private var title: String { card.isExitPlanMode ? "Claude 提交了一个计划" : "Claude 需要你选择" }

    /// Answered = the server says so OR we optimistically flipped it on submit.
    private var isAnswered: Bool {
        card.isAnswered || model.optimisticChoiceAnswers[card.requestId] != nil
    }
    /// The submit failed — show a red ! and let a tap reopen the poll to retry.
    private var isFailed: Bool { model.failedChoiceAnswers.contains(card.requestId) }
    private var answerSummary: String {
        card.answer ?? model.optimisticChoiceAnswers[card.requestId] ?? "已处理"
    }

    var body: some View {
        Group {
            if isFailed {
                Button { onOpen(card) } label: { failedCard }
                    .buttonStyle(.plain)
            } else if isAnswered {
                resolvedCard
            } else {
                Button { onOpen(card) } label: { pendingCard }
                    .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 260, alignment: .leading)
    }

    private var failedCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.red)
                .frame(width: 44, height: 44)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("发送失败,点击重试")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.red.opacity(0.5), lineWidth: 1))
    }

    private var pendingCard: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(accent, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Text("点击查看")
                    .font(.system(size: 11))
                    .foregroundStyle(accent)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent.opacity(0.4), lineWidth: 1))
    }

    private var resolvedCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(answerSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .opacity(0.85)
    }
}

// MARK: - IOSChoicePollSheet

struct IOSChoicePollSheet: View {
    let card: ChoiceCard
    let conversationId: String

    @Environment(IOSAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Per-question selected labels (keyed by question text).
    @State private var selections: [String: Set<String>] = [:]
    /// Free-text typed into the "其他" option, keyed by question text.
    @State private var customText: [String: String] = [:]
    @State private var submitting = false

    /// Internal marker for the always-present "其他(自己填)" option — replaced
    /// by the typed text when the answer is built.
    private static let otherKey = "__im_other__"

    private var accent: Color { WC.accent }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if card.isExitPlanMode {
                        planBody
                    } else {
                        questionsBody
                    }
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom) { footer }
            .navigationTitle(card.isExitPlanMode ? "审阅计划" : "请选择")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    // MARK: ExitPlanMode

    private var planBody: some View {
        MarkdownText(content: card.plan ?? "")
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: AskUserQuestion

    @ViewBuilder private var questionsBody: some View {
        ForEach(Array((card.questions ?? []).enumerated()), id: \.offset) { _, q in
            VStack(alignment: .leading, spacing: 10) {
                if let header = q.header, !header.isEmpty {
                    Text(header)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(accent.opacity(0.12), in: Capsule())
                }
                Text(q.question)
                    .font(.system(size: 15, weight: .semibold))
                ForEach(Array(q.options.enumerated()), id: \.offset) { _, opt in
                    optionRow(question: q, option: opt)
                }
                otherRow(question: q)
            }
        }
    }

    /// The always-available "其他" option: select it to reveal a free-text field.
    @ViewBuilder private func otherRow(question q: ChoiceQuestion) -> some View {
        let selected = selections[q.question]?.contains(Self.otherKey) ?? false
        let multi = q.allowsMultiple
        VStack(alignment: .leading, spacing: 6) {
            Button {
                toggle(question: q, label: Self.otherKey)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: multi
                          ? (selected ? "checkmark.square.fill" : "square")
                          : (selected ? "largecircle.fill.circle" : "circle"))
                        .font(.system(size: 18))
                        .foregroundStyle(selected ? accent : .secondary)
                    Text("其他(自己填)")
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(selected ? accent.opacity(0.10) : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? accent.opacity(0.5) : Color.clear, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            if selected {
                TextField("输入你的答案…", text: Binding(
                    get: { customText[q.question] ?? "" },
                    set: { customText[q.question] = $0 }
                ), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .submitLabel(.done)
            }
        }
    }

    /// Selected labels for a question, with "其他" resolved to its typed text
    /// (dropped when empty).
    private func resolvedLabels(for q: ChoiceQuestion) -> [String] {
        (selections[q.question] ?? []).compactMap { label in
            guard label == Self.otherKey else { return label }
            let t = customText[q.question]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? nil : t
        }
    }

    private func optionRow(question: ChoiceQuestion, option: ChoiceOption) -> some View {
        let selected = selections[question.question]?.contains(option.label) ?? false
        let multi = question.allowsMultiple
        return Button {
            toggle(question: question, label: option.label)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: multi
                      ? (selected ? "checkmark.square.fill" : "square")
                      : (selected ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                    if let d = option.description, !d.isEmpty {
                        Text(d)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(selected ? accent.opacity(0.10) : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? accent.opacity(0.5) : Color.clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func toggle(question: ChoiceQuestion, label: String) {
        var set = selections[question.question] ?? []
        if question.allowsMultiple {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = [label]
        }
        selections[question.question] = set
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        VStack {
            if card.isExitPlanMode {
                HStack(spacing: 12) {
                    Button { submit(approve: false) } label: {
                        Text("拒绝").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    Button { submit(approve: true) } label: {
                        Text("同意").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                }
                .disabled(submitting)
            } else {
                Button { submitAnswers() } label: {
                    Text(submitting ? "提交中…" : "提交")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .disabled(submitting || !allAnswered)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private var allAnswered: Bool {
        guard let qs = card.questions else { return false }
        return qs.allSatisfy { q in
            // A question is answered if it has at least one resolved label — which
            // means a plain option, or "其他" with non-empty typed text.
            !resolvedLabels(for: q).isEmpty
        }
    }

    private func submitAnswers() {
        var answers: [String: [String]] = [:]
        var parts: [String] = []
        for q in card.questions ?? [] {
            let labels = resolvedLabels(for: q)
            answers[q.question] = labels
            parts.append(contentsOf: labels)
        }
        let summary = parts.isEmpty ? "已选择" : "已选择 " + parts.joined(separator: " / ")
        submitting = true
        Task {
            await model.answerChoice(conversationId: conversationId, requestId: card.requestId,
                                     answers: answers, approve: nil, summary: summary)
            dismiss()
        }
    }

    private func submit(approve: Bool) {
        submitting = true
        Task {
            await model.answerChoice(conversationId: conversationId, requestId: card.requestId,
                                     answers: nil, approve: approve, summary: approve ? "已同意" : "已拒绝")
            dismiss()
        }
    }
}

// MARK: - IOSImageBubble
//
// Renders a `kind == "image"` IM message as an image bubble. The bytes require
// the JWT, so we fetch them via the model (APIClient) rather than an AsyncImage
// URL, decode to UIImage, and show it. Spinner while loading, fallback on error.

struct IOSImageBubble: View {
    let card: ImageCard

    @Environment(IOSAppModel.self) private var model
    @State private var image: UIImage?
    @State private var failed = false
    @State private var showFull = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(.separator), lineWidth: 0.5))
            if let cap = card.trimmedCaption {
                Text(cap).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .task(id: card.mediaId) { await load() }
        .sheet(isPresented: $showFull) {
            if let image { IOSImageFullView(card: card, thumbnail: image).environment(model) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 240, maxHeight: 320)
                .onTapGesture { showFull = true }
        } else if failed {
            placeholder(systemImage: "photo.badge.exclamationmark", text: "图片加载失败")
        } else {
            placeholder(systemImage: nil, text: nil).overlay(ProgressView())
        }
    }

    @ViewBuilder
    private func placeholder(systemImage: String?, text: String?) -> some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage) }
            if let text { Text(text).font(.system(size: 12)) }
        }
        .foregroundStyle(.secondary)
        .frame(width: 176, height: 112)
    }

    private func load() async {
        image = nil
        failed = false
        // Bubble shows the small thumbnail; the original is fetched on demand in
        // the full viewer (查看原图) — saves multi-MB downloads in the thread.
        if let data = await model.loadMedia(mediaId: card.mediaId, thumb: true), let ui = UIImage(data: data) {
            image = ui
        } else {
            failed = true
        }
    }
}

// Full-screen WeChat-style image viewer: shows the thumbnail instantly, with a
// "查看原图 (N MB)" button that downloads the full-res original on demand. Native
// pinch / double-tap zoom + pan; a 保存(to Photos) button (always saves the
// original); X to dismiss.
private struct IOSImageFullView: View {
    let card: ImageCard
    let thumbnail: UIImage

    @Environment(IOSAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var fullImage: UIImage?
    @State private var loadingFull = false
    @State private var saver = ImageSaver()
    @State private var toast: String?

    private var shown: UIImage { fullImage ?? thumbnail }
    private var viewOriginalLabel: String {
        card.sizeLabel.map { "查看原图 (\($0))" } ?? "查看原图"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZoomableImageView(image: shown).ignoresSafeArea()
            VStack {
                HStack {
                    iconButton("xmark") { dismiss() }
                    Spacer()
                    iconButton("square.and.arrow.down") { save() }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
                if fullImage == nil {
                    Button { Task { await loadFull() } } label: {
                        HStack(spacing: 6) {
                            if loadingFull { ProgressView().controlSize(.small).tint(.white) }
                            Text(loadingFull ? "加载中…" : viewOriginalLabel)
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.black.opacity(0.5), in: Capsule())
                    }
                    .disabled(loadingFull)
                    .padding(.bottom, 28)
                }
            }
            if let toast {
                Text(toast)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.65), in: Capsule())
            }
        }
        .statusBarHidden(true)
    }

    private func iconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.black.opacity(0.35), in: Circle())
        }
    }

    /// Download the full-res original (cached) and swap it in. Returns it.
    @discardableResult
    private func loadFull() async -> UIImage? {
        if let fullImage { return fullImage }
        loadingFull = true
        defer { loadingFull = false }
        guard let data = await model.loadMedia(mediaId: card.mediaId, thumb: false),
              let ui = UIImage(data: data) else { return nil }
        fullImage = ui
        return ui
    }

    /// Always saves the ORIGINAL — loads it first if the user hasn't yet.
    private func save() {
        Task {
            let img = await loadFull() ?? thumbnail
            saver.onComplete = { err in
                withAnimation { toast = err == nil ? "已保存原图到相册" : "保存失败" }
                Task {
                    try? await Task.sleep(nanoseconds: 1_800_000_000)
                    withAnimation { toast = nil }
                }
            }
            saver.save(img)
        }
    }
}

// UIScrollView-backed zoomable image — native pinch, double-tap, and pan, just
// like the WeChat photo viewer.
private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomScrollView {
        let sv = ZoomScrollView()
        sv.delegate = context.coordinator
        sv.minimumZoomScale = 1
        sv.maximumZoomScale = 4
        sv.showsVerticalScrollIndicator = false
        sv.showsHorizontalScrollIndicator = false
        sv.backgroundColor = .clear
        sv.contentInsetAdjustmentBehavior = .never
        sv.imageView.image = image
        sv.imageView.contentMode = .scaleAspectFit
        sv.imageView.isUserInteractionEnabled = true
        sv.addSubview(sv.imageView)
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        sv.imageView.addGestureRecognizer(doubleTap)
        context.coordinator.scrollView = sv
        return sv
    }

    func updateUIView(_ uiView: ZoomScrollView, context: Context) {
        if uiView.imageView.image !== image { uiView.imageView.image = image }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: ZoomScrollView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomScrollView)?.imageView
        }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let iv = (scrollView as? ZoomScrollView)?.imageView else { return }
            let w = scrollView.bounds.width, h = scrollView.bounds.height
            let cw = scrollView.contentSize.width, ch = scrollView.contentSize.height
            iv.center = CGPoint(x: max(cw, w) / 2, y: max(ch, h) / 2)
        }
        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let sv = scrollView else { return }
            if sv.zoomScale > sv.minimumZoomScale {
                sv.setZoomScale(sv.minimumZoomScale, animated: true)
            } else {
                let loc = g.location(in: sv.imageView)
                let zw = sv.bounds.width / sv.maximumZoomScale
                let zh = sv.bounds.height / sv.maximumZoomScale
                sv.zoom(to: CGRect(x: loc.x - zw / 2, y: loc.y - zh / 2, width: zw, height: zh), animated: true)
            }
        }
    }
}

private final class ZoomScrollView: UIScrollView {
    let imageView = UIImageView()
    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == minimumZoomScale {
            imageView.frame = bounds
        }
    }
}

// Saves a UIImage to the photo library (needs NSPhotoLibraryAddUsageDescription).
private final class ImageSaver: NSObject {
    var onComplete: ((Error?) -> Void)?
    func save(_ image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(
            image, self, #selector(done(_:didFinishSavingWithError:contextInfo:)), nil)
    }
    @objc private func done(_ image: UIImage, didFinishSavingWithError error: Error?,
                            contextInfo: UnsafeRawPointer) {
        onComplete?(error)
    }
}
