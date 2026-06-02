// MARK: - Failed-message resend helpers
//
// Pure logic shared by WeChatChatPane's `onResend` and covered by resend.test.ts.
// Keeping this out of the React component lets us unit-test the decision rules
// (eligibility + which payload to re-send) without a DOM/render harness.

import type { WeChatMessage } from './WeChatMessageBubble';

export interface ResendPayload {
  text: string;
  images?: { data: string; name: string }[];
}

/**
 * Only a *failed outgoing* (user) bubble may be resent. Streaming assistant
 * messages, tool cards, already-sent messages, etc. are never eligible.
 */
export function canResend(message: Pick<WeChatMessage, 'role' | 'sendStatus'>): boolean {
  return message.role === 'user' && message.sendStatus === 'failed';
}

/**
 * Resolve the exact wire payload to replay for a failed bubble. Prefers the
 * `resend` snapshot captured at first send (text already composed with quote /
 * file refs, plus images); falls back to the rendered `content` when an older
 * bubble has no snapshot. Returns null when the message isn't resendable.
 */
export function resolveResendPayload(
  message: Pick<WeChatMessage, 'role' | 'sendStatus' | 'content' | 'resend'>,
): ResendPayload | null {
  if (!canResend(message)) return null;
  if (message.resend) {
    return {
      text: message.resend.text,
      images: message.resend.images,
    };
  }
  return { text: message.content };
}
