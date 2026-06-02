// Pure URL builders for the IM REST endpoints. Kept dependency-free (no
// imports that touch the DOM / import.meta.env) so they're unit-testable under
// the Node test runner.

export function buildSyncUrl(since: number, recent?: number): string {
  let url = `/api/im/sync?since=${encodeURIComponent(String(since))}`;
  // Cold-start cap: only appended when > 0. The server returns just the last N
  // messages per conversation and jumps the cursor to its max rev.
  if (recent !== undefined && recent > 0) {
    url += `&recent=${encodeURIComponent(String(recent))}`;
  }
  return url;
}

export function buildMessagesUrl(
  conversationId: string,
  opts: { anchorSeq?: number; numBefore: number; numAfter: number }
): string {
  const params = new URLSearchParams();
  if (opts.anchorSeq !== undefined) params.set('anchor', String(opts.anchorSeq));
  params.set('numBefore', String(opts.numBefore));
  params.set('numAfter', String(opts.numAfter));
  return `/api/im/conversations/${encodeURIComponent(conversationId)}/messages?${params.toString()}`;
}

export function buildMessageContentUrl(
  conversationId: string,
  messageId: string
): string {
  return `/api/im/conversations/${encodeURIComponent(conversationId)}/messages/${encodeURIComponent(
    messageId
  )}/content`;
}

export function buildTranscriptUrl(
  conversationId: string,
  opts: { anchor?: string; numBefore: number; numAfter: number }
): string {
  const params = new URLSearchParams();
  if (opts.anchor !== undefined) params.set('anchor', opts.anchor);
  params.set('numBefore', String(opts.numBefore));
  params.set('numAfter', String(opts.numAfter));
  return `/api/im/conversations/${encodeURIComponent(conversationId)}/transcript?${params.toString()}`;
}
