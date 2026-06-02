// MARK: - WebSocket reconnect backoff
//
// Pure helper extracted from WebSocketContext so the reconnect schedule is
// unit-testable without a DOM/WebSocket. Mirrors the Apple ChatSocket backoff
// sequence (1,2,4,8,16,30s) but adds jitter so a fleet of clients reconnecting
// after a server restart doesn't thundering-herd the backend.

/** Base delay per reconnect attempt (0-based), in ms. Caps at 30s. */
export const BACKOFF_SEQUENCE_MS = [1000, 2000, 4000, 8000, 16000, 30000];

/**
 * Delay (ms) before the Nth reconnect attempt, with "half jitter": the base is
 * picked from BACKOFF_SEQUENCE_MS (clamped to the last entry), then the result
 * is randomized into the range [base/2, base]. `rng` is injectable for tests.
 */
export function computeBackoffDelay(attempt: number, rng: () => number = Math.random): number {
  const i = Math.max(0, Math.min(attempt, BACKOFF_SEQUENCE_MS.length - 1));
  const base = BACKOFF_SEQUENCE_MS[i];
  const half = base / 2;
  return Math.round(half + rng() * half);
}
