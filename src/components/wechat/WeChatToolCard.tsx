import { useMemo, useState } from 'react';
import { ChevronDown, ChevronRight, Wrench } from 'lucide-react';

// MARK: - WeChatToolCard
//
// 1:1 port of the macOS `ToolCard` view + the tool-card slot rendered by
// `MessageBubble.swift` when `message.role == .tool`.
//
// Visual contract (matches SwiftUI output as closely as Tailwind lets us):
//   - Off-white card (`bg-zinc-100/60`) with a 1px border and 6px radius.
//   - Header row: small wrench icon + tool name + (optionally) "待批准" pill.
//   - Two collapsible panels: "输入" (monospace pretty-printed JSON) and
//     "输出" (raw text or error). Both default collapsed.
//   - When `requiresApproval` is true and the request is still pending,
//     two pill buttons show: 拒绝 (zinc) / 允许 (green).

export interface WeChatToolPayload {
  /** Display name (e.g. "Read", "Bash"). */
  name: string;
  /** Optional input — string, object, or anything JSON-serializable. */
  input?: unknown;
  /** Tool result content as plain text (already concat'd). */
  output?: string;
  /** Whether the tool result was an error. */
  isError?: boolean;
  /** SDK approval flow. When true → show Approve/Reject. */
  requiresApproval?: boolean;
  /** Server-issued request id used to RPC the approval back. */
  requestId?: string;
}

interface Props {
  payload: WeChatToolPayload;
  onApprove?: () => void;
  onReject?: () => void;
  /** Default-open the panels even when collapsed by user preference. */
  defaultExpanded?: boolean;
}

function tryJsonPretty(value: unknown): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (typeof value === 'string') {
    // Some servers emit `toolInput` as a JSON-encoded string; un-quote when so.
    const trimmed = value.trim();
    if (
      (trimmed.startsWith('{') && trimmed.endsWith('}')) ||
      (trimmed.startsWith('[') && trimmed.endsWith(']'))
    ) {
      try {
        return JSON.stringify(JSON.parse(trimmed), null, 2);
      } catch {
        return value;
      }
    }
    return value;
  }
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

export default function WeChatToolCard({
  payload,
  onApprove,
  onReject,
  defaultExpanded = false,
}: Props) {
  const [inputOpen, setInputOpen] = useState<boolean>(defaultExpanded);
  const [outputOpen, setOutputOpen] = useState<boolean>(defaultExpanded);

  const inputText = useMemo(() => tryJsonPretty(payload.input), [payload.input]);
  const output = payload.output?.trim() ?? '';
  const hasInput = inputText.length > 0;
  const hasOutput = output.length > 0;

  return (
    <div className="w-full max-w-[520px] overflow-hidden rounded-md border border-zinc-200 bg-zinc-100/60 dark:border-zinc-700 dark:bg-zinc-800/60">
      {/* Header */}
      <div className="flex items-center gap-2 px-2.5 py-1.5">
        <Wrench className="h-3.5 w-3.5 shrink-0 text-[#07c160]" />
        <span className="truncate text-[12px] font-medium text-zinc-900 dark:text-zinc-100">
          {payload.name || '工具调用'}
        </span>
        {payload.requiresApproval && (
          <span className="ml-1 rounded-full bg-orange-500 px-1.5 py-px text-[9px] font-medium text-white">
            待批准
          </span>
        )}
        {payload.isError && (
          <span className="ml-1 rounded-full bg-red-500 px-1.5 py-px text-[9px] font-medium text-white">
            错误
          </span>
        )}
      </div>

      {/* Input panel */}
      {hasInput && (
        <div className="border-t border-zinc-200/70 dark:border-zinc-700/70">
          <button
            type="button"
            onClick={() => setInputOpen((v) => !v)}
            className="flex w-full items-center gap-1.5 px-2.5 py-1 text-left text-[10px] uppercase tracking-wider text-zinc-500 hover:bg-zinc-200/40 dark:text-zinc-400 dark:hover:bg-zinc-700/40"
          >
            {inputOpen ? (
              <ChevronDown className="h-3 w-3" />
            ) : (
              <ChevronRight className="h-3 w-3" />
            )}
            输入
          </button>
          {inputOpen && (
            <pre className="max-h-[200px] overflow-auto whitespace-pre-wrap break-words bg-white/60 px-2.5 py-1.5 font-mono text-[11px] leading-snug text-zinc-800 dark:bg-zinc-900/60 dark:text-zinc-200">
              {inputText}
            </pre>
          )}
        </div>
      )}

      {/* Output panel */}
      {hasOutput && (
        <div className="border-t border-zinc-200/70 dark:border-zinc-700/70">
          <button
            type="button"
            onClick={() => setOutputOpen((v) => !v)}
            className="flex w-full items-center gap-1.5 px-2.5 py-1 text-left text-[10px] uppercase tracking-wider text-zinc-500 hover:bg-zinc-200/40 dark:text-zinc-400 dark:hover:bg-zinc-700/40"
          >
            {outputOpen ? (
              <ChevronDown className="h-3 w-3" />
            ) : (
              <ChevronRight className="h-3 w-3" />
            )}
            输出
          </button>
          {outputOpen && (
            <pre
              className={[
                'max-h-[260px] overflow-auto whitespace-pre-wrap break-words px-2.5 py-1.5 font-mono text-[11px] leading-snug',
                payload.isError
                  ? 'bg-red-50 text-red-700 dark:bg-red-950/40 dark:text-red-300'
                  : 'bg-white/60 text-zinc-800 dark:bg-zinc-900/60 dark:text-zinc-200',
              ].join(' ')}
            >
              {output}
            </pre>
          )}
        </div>
      )}

      {/* Approval buttons */}
      {payload.requiresApproval && (onApprove || onReject) && (
        <div className="flex items-center justify-end gap-2 border-t border-zinc-200/70 px-2.5 py-1.5 dark:border-zinc-700/70">
          {onReject && (
            <button
              type="button"
              onClick={onReject}
              className="rounded px-2 py-1 text-[11px] font-medium text-zinc-700 hover:bg-zinc-200 dark:text-zinc-300 dark:hover:bg-zinc-700"
            >
              拒绝
            </button>
          )}
          {onApprove && (
            <button
              type="button"
              onClick={onApprove}
              className="rounded bg-[#07c160] px-2.5 py-1 text-[11px] font-medium text-white hover:bg-[#06ad55]"
            >
              允许
            </button>
          )}
        </div>
      )}
    </div>
  );
}
