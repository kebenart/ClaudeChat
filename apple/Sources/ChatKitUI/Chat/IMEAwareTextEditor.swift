import AppKit
import SwiftUI

// MARK: - IMEAwareTextEditor
//
// A multi-line text input that handles ↩ = send / ⇧↩ = newline CORRECTLY for
// input methods (中文/日文/etc.).
//
// Why not SwiftUI's TextEditor + .onKeyPress(.return)? That intercept fires at
// the SwiftUI key layer, BEFORE the input method's marked-text (组字) handling.
// So pressing ↩ to CONFIRM a candidate word — while still composing — was being
// swallowed as "send", firing a half-typed message.
//
// AppKit's NSTextView already does the right thing: while there is marked text,
// the IME consumes ↩ to commit the candidate and `insertNewline(_:)` is NEVER
// called. We override `insertNewline(_:)` (and check `hasMarkedText()` as a
// belt-and-suspenders) so ↩ only sends when the user is genuinely NOT composing.

struct IMEAwareTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .systemFont(ofSize: 13)
    var onSend: () -> Void
    /// Called whenever the text changes (so callers can run their own onChange).
    var onChange: (String) -> Void = { _ in }
    /// Height bounds. An NSScrollView has NO intrinsic size, so without an
    /// explicit `sizeThatFits` SwiftUI keeps re-proposing sizes against the
    /// flexible `.frame(minHeight:maxHeight:)` and the layout solver can fail to
    /// converge — a 15s main-thread hang. We resolve a concrete height here and
    /// report it, breaking the loop.
    var minHeight: CGFloat = 34
    var maxHeight: CGFloat = 120

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // Give SwiftUI a DETERMINISTIC size so the layout solver converges. Width =
    // whatever was proposed (fill); height = the text's content height clamped to
    // [minHeight, maxHeight]. Without this the NSScrollView's lack of an intrinsic
    // size sent the solver into a non-terminating sizeThatFits recursion.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.frame.width
        guard width > 0, let tv = nsView.documentView as? SendingTextView,
              let lm = tv.layoutManager, let tc = tv.textContainer else {
            return CGSize(width: width.isFinite ? width : 200, height: minHeight)
        }
        // Measure the text's laid-out height at the proposed width.
        tc.containerSize = NSSize(width: max(0, width - 2 * tv.textContainerInset.width),
                                  height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let textHeight = lm.usedRect(for: tc).height + 2 * tv.textContainerInset.height
        let h = min(max(textHeight, minHeight), maxHeight)
        return CGSize(width: width, height: h)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Build the SendingTextView + its text system by hand: the convenience
        // NSTextView.scrollableTextView() makes a plain NSTextView, not our
        // subclass, so the ↩ override wouldn't fire.
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let contentSize = scroll.contentSize
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: contentSize.width,
                                                             height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let textView = SendingTextView(frame: NSRect(origin: .zero, size: contentSize),
                                       textContainer: container)
        textView.delegate = context.coordinator
        textView.onSend = onSend
        textView.font = font
        textView.string = text
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scroll.documentView = textView
        // Take focus once the view is in a window. Because the composer is keyed
        // by conversation id (a fresh editor per chat), this makes the input
        // immediately typable after switching conversations instead of requiring
        // a manual click.
        DispatchQueue.main.async { [weak textView] in
            textView?.window?.makeFirstResponder(textView)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? SendingTextView else { return }
        textView.onSend = onSend
        // Only push external changes (e.g. clear-on-send, draft restore) into the
        // view when they DON'T match — never clobber the user's live edit or the
        // input method's marked text.
        if textView.string != text {
            // Don't overwrite mid-composition: that would drop the candidate.
            if !textView.hasMarkedText() {
                textView.string = text
            }
        }
        if textView.font != font { textView.font = font }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: IMEAwareTextEditor
        init(_ parent: IMEAwareTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Ignore change events fired while组字 — the text isn't final yet and
            // syncing marked text into the binding causes flicker / lost candidates.
            if tv.hasMarkedText() { return }
            parent.text = tv.string
            parent.onChange(tv.string)
        }
    }
}

// MARK: - SendingTextView
//
// NSTextView subclass whose ↩ sends (when not composing) and ⇧↩ inserts a real
// newline. The IME-safety comes for free: `insertNewline(_:)` is only invoked
// once the input method has finished composing.
final class SendingTextView: NSTextView {
    var onSend: (() -> Void)?

    override func insertNewline(_ sender: Any?) {
        // Defensive: if there's still marked text, let AppKit/IME handle it.
        if hasMarkedText() {
            super.insertNewline(sender)
            return
        }
        // ⇧↩ → real newline; plain ↩ → send.
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            super.insertNewline(sender)
        } else {
            onSend?()
        }
    }
}
