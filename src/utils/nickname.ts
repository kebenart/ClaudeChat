// Nicknames render at most 10 characters; longer names are truncated with an
// ellipsis. Shared by the session list and chat header so the rule matches the
// iOS and macOS clients. (CSS `truncate` only clips by width — this enforces a
// hard character cap regardless of available space.)
export function clampNickname(name: string | null | undefined): string {
  const s = name ?? '';
  return [...s].length > 10 ? [...s].slice(0, 10).join('') + '…' : s;
}
