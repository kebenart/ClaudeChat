// Per-conversation composer draft cache (localStorage). A half-typed message
// survives switching sessions / reloading. Empty drafts are removed.
const key = (conversationId: string) => `im_draft_${conversationId}`;

export function loadDraft(conversationId: string): string {
  try { return localStorage.getItem(key(conversationId)) ?? ''; } catch { return ''; }
}
export function saveDraft(conversationId: string, text: string): void {
  try {
    if (text.trim() === '') localStorage.removeItem(key(conversationId));
    else localStorage.setItem(key(conversationId), text);
  } catch { /* ignore quota/private-mode */ }
}
export function clearDraft(conversationId: string): void {
  try { localStorage.removeItem(key(conversationId)); } catch { /* ignore */ }
}
