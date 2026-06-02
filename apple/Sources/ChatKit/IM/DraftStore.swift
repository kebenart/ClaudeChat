import Foundation

/// Per-conversation composer draft cache (UserDefaults). Lets a half-typed
/// message survive navigating away from a chat. Empty/whitespace drafts are
/// removed so they don't linger.
///
/// Writes are DEBOUNCED and bounded: persisting on every keystroke synchronously
/// wrote the full string to disk, which froze the UI when a huge (e.g. 90k)
/// paste landed. We now coalesce rapid edits into a single trailing write, run it
/// off the main thread, and skip persistence entirely for very large drafts
/// (UserDefaults is the wrong store for big blobs — the in-memory draft still
/// works for the current session; it just won't survive an app restart).
public enum DraftStore {
    private static func key(_ conversationId: String) -> String { "im_draft_\(conversationId)" }

    /// Drafts larger than this are never written to UserDefaults — they'd bloat
    /// the plist and stall every read/write. ~64k chars is far above any real
    /// hand-typed message; a paste that big is a one-shot send, not a draft.
    private static let maxPersistedChars = 64_000

    private static let debounceQueue = DispatchQueue(label: "im.draftstore.debounce")
    /// Pending debounced write items, keyed by conversation id, so a later edit
    /// cancels the earlier scheduled write.
    nonisolated(unsafe) private static var pending: [String: DispatchWorkItem] = [:]
    private static let lock = NSLock()

    public static func load(_ conversationId: String) -> String {
        UserDefaults.standard.string(forKey: key(conversationId)) ?? ""
    }

    /// Schedule a debounced, off-main write. Coalesces bursts (typing / a big
    /// paste's onChange storm) into one trailing disk write ~0.4s after the last
    /// edit. Oversized drafts are dropped from persistence (and any stale value
    /// for that conversation is cleared).
    public static func save(_ text: String, for conversationId: String) {
        let k = key(conversationId)

        lock.lock()
        pending[conversationId]?.cancel()
        let work = DispatchWorkItem {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || text.count > maxPersistedChars {
                UserDefaults.standard.removeObject(forKey: k)
            } else {
                UserDefaults.standard.set(text, forKey: k)
            }
            lock.lock(); pending[conversationId] = nil; lock.unlock()
        }
        pending[conversationId] = work
        lock.unlock()

        debounceQueue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    public static func clear(_ conversationId: String) {
        lock.lock()
        pending[conversationId]?.cancel()
        pending[conversationId] = nil
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: key(conversationId))
    }
}
