// MARK: - IM toast bus
//
// A tiny window-event bus so any IM module (the sync controller in IMContext,
// the optimistic mutations in useSessionMeta) can surface a transient failure
// toast WITHOUT threading a React context through every consumer. <IMToast>
// (mounted by IMProvider) listens for 'im:toast' and renders the banner.
// Mirrors the macOS/iOS `pushOrToast` behaviour — a rejected /state or /sync
// no longer fails silently.

export type ImToastKind = 'error' | 'info';

export interface ImToastDetail {
  message: string;
  kind: ImToastKind;
}

export function imToast(message: string, kind: ImToastKind = 'error'): void {
  if (typeof window === 'undefined') return;
  window.dispatchEvent(new CustomEvent<ImToastDetail>('im:toast', { detail: { message, kind } }));
}
