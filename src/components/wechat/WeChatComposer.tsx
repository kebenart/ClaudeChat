import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Command, Image as ImageIcon, Paperclip, Smile, Camera, X, Plus } from 'lucide-react';

import WeChatSlashCommandPicker, {
  type WeChatCommand,
} from './WeChatSlashCommandPicker';

// MARK: - WeChatComposer
//
// 1:1 port of `Sources/ChatKit/UI/Chat/ComposerView.swift`.
//
// Layout (top to bottom):
//   1. Quote chip row (only when `pendingQuote` set)
//   2. Attachment strip (only when there are pending images / files)
//   3. Toolbar (30px): `/` button (anchor for picker) + 表情/附件/图片/截图
//      decorative buttons + "命令模式" hint chip on the right.
//   4. Textarea (min 60px, max 120px, autosize).
//   5. Footer row: hint + green Send button.
//
// Keybinds:
//   - Enter or Cmd+Enter → send.
//   - Shift+Enter → newline.

export interface WeChatPendingImage {
  id: string;
  filename: string;
  mimeType: string;
  /** Full data URI: `data:image/png;base64,XXXX`. */
  dataURI: string;
}

export interface WeChatSendPayload {
  text: string;
  images?: WeChatPendingImage[];
  files?: string[];
  quote?: string | null;
}

interface Props {
  /** Optional draft text controlled by the parent. */
  value?: string;
  onChange?: (text: string) => void;
  /** Project path used to power the slash-command picker. */
  projectPath?: string | null;
  /** Quote chip text — pass null to clear. */
  pendingQuote?: string | null;
  onClearQuote?: () => void;
  pendingImages?: WeChatPendingImage[];
  onRemoveImage?: (id: string) => void;
  pendingFiles?: string[];
  onRemoveFile?: (path: string) => void;
  onSendMessage: (payload: WeChatSendPayload) => void;
  /** When true, the send button is disabled regardless of text content. */
  disabled?: boolean;
  /** Autofocus the textarea on mount / when session changes. */
  autoFocus?: boolean;
  /** When true, render the WeChat-iOS single-row composer instead of the
   * desktop-style toolbar + multiline composer. */
  isMobile?: boolean;
}

const MIN_HEIGHT = 60;
const MAX_HEIGHT = 120;

function autoResize(el: HTMLTextAreaElement) {
  el.style.height = `${MIN_HEIGHT}px`;
  const next = Math.min(MAX_HEIGHT, Math.max(MIN_HEIGHT, el.scrollHeight));
  el.style.height = `${next}px`;
}

export default function WeChatComposer({
  value,
  onChange,
  projectPath,
  pendingQuote,
  onClearQuote,
  pendingImages,
  onRemoveImage,
  pendingFiles,
  onRemoveFile,
  onSendMessage,
  disabled,
  autoFocus,
  isMobile,
}: Props) {
  const [internal, setInternal] = useState(value ?? '');
  const isControlled = value !== undefined;
  const text = isControlled ? (value ?? '') : internal;
  const setText = useCallback(
    (next: string) => {
      if (!isControlled) setInternal(next);
      onChange?.(next);
    },
    [isControlled, onChange],
  );

  const taRef = useRef<HTMLTextAreaElement | null>(null);
  const slashBtnRef = useRef<HTMLButtonElement | null>(null);
  const [showPicker, setShowPicker] = useState(false);

  // Auto-resize on text change.
  useEffect(() => {
    if (taRef.current) autoResize(taRef.current);
  }, [text]);

  useEffect(() => {
    if (autoFocus && taRef.current) {
      taRef.current.focus();
    }
  }, [autoFocus]);

  // Detect slash-command mode.
  const isSlashCommand = useMemo(() => {
    const t = text.trim();
    return t.startsWith('/') && !t.includes(' ');
  }, [text]);

  // Auto open/close picker as the user types.
  useEffect(() => {
    if (isSlashCommand && !showPicker) {
      setShowPicker(true);
    } else if (!isSlashCommand && showPicker) {
      setShowPicker(false);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isSlashCommand]);

  const canSend = !disabled && text.trim().length > 0;

  const send = useCallback(() => {
    const trimmed = text.trim();
    if (!trimmed) return;
    setShowPicker(false);
    onSendMessage({
      text: trimmed,
      images: pendingImages,
      files: pendingFiles,
      quote: pendingQuote ?? null,
    });
    setText('');
    if (taRef.current) {
      taRef.current.style.height = `${MIN_HEIGHT}px`;
    }
  }, [text, pendingImages, pendingFiles, pendingQuote, onSendMessage, setText]);

  const onKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    // Allow picker to consume arrow/Enter/Escape first.
    if (showPicker && ['ArrowDown', 'ArrowUp', 'Enter', 'Escape'].includes(e.key)) {
      return;
    }
    if (e.key === 'Enter' && !e.shiftKey) {
      // Cmd+Enter or plain Enter — both send (Shift+Enter is newline).
      e.preventDefault();
      send();
    }
  };

  const onPickCommand = (cmd: WeChatCommand) => {
    setText(`${cmd.name} `);
    setShowPicker(false);
    taRef.current?.focus();
  };

  // ── Mobile (iOS WeChat) layout ───────────────────────────────────────────
  // Single rounded row: mic toggle | input pill | plus / emoji / send.
  // Voice is NOT implemented (user opted out); the mic icon is a no-op for now
  // and stays as a visual nod to WeChat. Send button replaces emoji+plus when
  // the user has typed something.
  if (isMobile) {
    return (
      <div
        className="border-t border-zinc-200 bg-[#f7f7f7] dark:border-zinc-700 dark:bg-zinc-900"
        style={{ paddingBottom: 'max(env(safe-area-inset-bottom), 8px)' }}
      >
        {/* Quote chip (mobile keeps it above the row, compact) */}
        {pendingQuote && (
          <div className="mx-2 mb-1 mt-1 flex items-start gap-1.5 rounded-md bg-white/80 px-2 py-1 dark:bg-zinc-800/60">
            <span className="mt-px block w-[3px] self-stretch bg-[#07c160]" />
            <div className="min-w-0 flex-1">
              <div className="line-clamp-1 text-[11px] text-zinc-800 dark:text-zinc-200">
                {pendingQuote}
              </div>
            </div>
            {onClearQuote && (
              <button type="button" onClick={onClearQuote} aria-label="清除引用">
                <X className="h-3 w-3 text-zinc-400" />
              </button>
            )}
          </div>
        )}

        {/* Attachment strip (reuses the same chips, just compacted) */}
        {((pendingImages && pendingImages.length > 0) ||
          (pendingFiles && pendingFiles.length > 0)) && (
          <div className="overflow-x-auto px-2 py-1">
            <div className="flex items-center gap-1.5">
              {(pendingImages ?? []).map((img) => (
                <span
                  key={img.id}
                  className="inline-flex items-center gap-1 rounded border border-zinc-300 bg-white px-1.5 py-0.5 text-[10px] dark:border-zinc-700 dark:bg-zinc-900"
                >
                  <ImageIcon className="h-3 w-3 text-[#07c160]" />
                  <span className="max-w-[120px] truncate">{img.filename}</span>
                  {onRemoveImage && (
                    <button type="button" onClick={() => onRemoveImage(img.id)}>
                      <X className="h-3 w-3 text-zinc-400" />
                    </button>
                  )}
                </span>
              ))}
              {(pendingFiles ?? []).map((path) => (
                <span
                  key={path}
                  className="inline-flex items-center gap-1 rounded border border-zinc-300 bg-white px-1.5 py-0.5 text-[10px] dark:border-zinc-700 dark:bg-zinc-900"
                >
                  <Paperclip className="h-3 w-3 text-zinc-500" />
                  <span className="max-w-[120px] truncate">{path.split('/').pop() || path}</span>
                  {onRemoveFile && (
                    <button type="button" onClick={() => onRemoveFile(path)}>
                      <X className="h-3 w-3 text-zinc-400" />
                    </button>
                  )}
                </span>
              ))}
            </div>
          </div>
        )}

        {/* Single rounded row */}
        <div className="flex items-center gap-2 px-2 pb-2 pt-1.5">
          {/* Input pill */}
          <div className="flex min-w-0 flex-1 items-center rounded-md border border-zinc-300 bg-white px-2 py-1 dark:border-zinc-700 dark:bg-zinc-950">
            <textarea
              ref={taRef}
              value={text}
              onChange={(e) => setText(e.target.value)}
              onKeyDown={(e) => {
                // On mobile, Enter inserts newline; only an explicit tap on the
                // green Send button (right of the input) actually sends.
                if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
                  e.preventDefault();
                  send();
                }
              }}
              className="block w-0 flex-1 resize-none border-0 bg-transparent px-1 py-1 text-[14px] leading-snug text-zinc-900 focus:outline-none dark:text-zinc-100"
              style={{ minHeight: 28, maxHeight: 100 }}
              rows={1}
            />
          </div>

          {/* Either emoji+plus (idle) or send button (typing) */}
          {canSend ? (
            <button
              type="button"
              onClick={send}
              className="flex h-9 shrink-0 items-center justify-center rounded-md bg-[#07c160] px-4 text-[13px] font-medium text-white"
              aria-label="发送"
            >
              发送
            </button>
          ) : (
            <>
              <button
                type="button"
                className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full text-zinc-500"
                aria-label="表情"
                title="表情 (未启用)"
              >
                <Smile className="h-5 w-5" />
              </button>
              <button
                type="button"
                className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full text-zinc-500"
                aria-label="更多"
                title="更多 (未启用)"
              >
                <Plus className="h-5 w-5" />
              </button>
            </>
          )}
        </div>
      </div>
    );
  }

  // ── Desktop layout (existing) ────────────────────────────────────────────
  return (
    <div className="border-t border-zinc-200 bg-[#f7f7f7] dark:border-zinc-700 dark:bg-zinc-900">
      {/* Quote chip */}
      {pendingQuote && (
        <div className="flex items-start gap-2 bg-white/60 px-3 py-1.5 dark:bg-zinc-800/60">
          <span className="mt-px block w-[3px] self-stretch bg-[#07c160]" />
          <div className="min-w-0 flex-1">
            <div className="text-[10px] text-zinc-500 dark:text-zinc-400">引用消息</div>
            <div className="line-clamp-2 text-[11px] text-zinc-800 dark:text-zinc-200">
              {pendingQuote}
            </div>
          </div>
          {onClearQuote && (
            <button
              type="button"
              onClick={onClearQuote}
              className="rounded p-0.5 text-zinc-400 hover:bg-zinc-200 hover:text-zinc-700 dark:hover:bg-zinc-700 dark:hover:text-zinc-200"
              aria-label="清除引用"
            >
              <X className="h-3 w-3" />
            </button>
          )}
        </div>
      )}

      {/* Attachment strip */}
      {((pendingImages && pendingImages.length > 0) ||
        (pendingFiles && pendingFiles.length > 0)) && (
        <div className="overflow-x-auto bg-white/40 px-3 py-1.5 dark:bg-zinc-800/40">
          <div className="flex items-center gap-1.5">
            {(pendingImages ?? []).map((img) => (
              <span
                key={img.id}
                className="inline-flex items-center gap-1 rounded border border-zinc-300 bg-white px-2 py-1 text-[10px] dark:border-zinc-700 dark:bg-zinc-900"
              >
                <ImageIcon className="h-3 w-3 text-[#07c160]" />
                <span className="max-w-[160px] truncate text-zinc-800 dark:text-zinc-200">
                  {img.filename}
                </span>
                {onRemoveImage && (
                  <button
                    type="button"
                    onClick={() => onRemoveImage(img.id)}
                    className="text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200"
                  >
                    <X className="h-3 w-3" />
                  </button>
                )}
              </span>
            ))}
            {(pendingFiles ?? []).map((path) => {
              const name = path.split('/').pop() || path;
              return (
                <span
                  key={path}
                  title={path}
                  className="inline-flex items-center gap-1 rounded border border-zinc-300 bg-white px-2 py-1 text-[10px] dark:border-zinc-700 dark:bg-zinc-900"
                >
                  <Paperclip className="h-3 w-3 text-zinc-500" />
                  <span className="max-w-[160px] truncate text-zinc-800 dark:text-zinc-200">
                    {name}
                  </span>
                  {onRemoveFile && (
                    <button
                      type="button"
                      onClick={() => onRemoveFile(path)}
                      className="text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200"
                    >
                      <X className="h-3 w-3" />
                    </button>
                  )}
                </span>
              );
            })}
          </div>
        </div>
      )}

      {/* Toolbar */}
      <div className="relative flex h-[30px] items-center gap-3.5 border-t border-zinc-200/70 px-3 dark:border-zinc-700/70">
        <button
          ref={slashBtnRef}
          type="button"
          onClick={() => {
            setText('/');
            setShowPicker(true);
            taRef.current?.focus();
          }}
          className="text-[#6a6a6a] hover:text-zinc-900 dark:hover:text-zinc-100"
          title="Claude Code 命令 (输入 / 触发)"
        >
          <Command className="h-4 w-4" />
        </button>
        <button
          type="button"
          className="text-[#6a6a6a] hover:text-zinc-900 dark:hover:text-zinc-100"
          title="表情"
        >
          <Smile className="h-[18px] w-[18px]" />
        </button>
        <button
          type="button"
          className="text-[#6a6a6a] hover:text-zinc-900 dark:hover:text-zinc-100"
          title="附件"
        >
          <Paperclip className="h-[18px] w-[18px]" />
        </button>
        <button
          type="button"
          className="text-[#6a6a6a] hover:text-zinc-900 dark:hover:text-zinc-100"
          title="图片"
        >
          <ImageIcon className="h-[18px] w-[18px]" />
        </button>
        <button
          type="button"
          className="text-[#6a6a6a] hover:text-zinc-900 dark:hover:text-zinc-100"
          title="截图"
        >
          <Camera className="h-[18px] w-[18px]" />
        </button>
        <div className="flex-1" />
        {isSlashCommand && (
          <span className="flex items-center gap-1 text-[10px] text-[#07c160]">
            <Command className="h-2.5 w-2.5" />
            命令模式 — 发送将作为 Claude Code 命令执行
          </span>
        )}

        {/* Slash command picker — anchored above the toolbar so it doesn't
            block the textarea. */}
        {showPicker && (
          <WeChatSlashCommandPicker
            projectPath={projectPath}
            query={text}
            anchorEl={slashBtnRef.current}
            onPick={onPickCommand}
            onClose={() => setShowPicker(false)}
          />
        )}
      </div>

      {/* Textarea */}
      <div className="border-t border-zinc-200/70 bg-[#f7f7f7] dark:border-zinc-700/70 dark:bg-zinc-900">
        <textarea
          ref={taRef}
          value={text}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={onKeyDown}
          /* No placeholder — clean empty composer */
          className="block w-full resize-none border-0 bg-transparent px-4 pt-3 pb-2 text-[13px] leading-snug text-zinc-900 focus:outline-none dark:text-zinc-100"
          style={{ minHeight: MIN_HEIGHT, maxHeight: MAX_HEIGHT }}
          rows={2}
        />
      </div>

      {/* Footer */}
      <div className="flex items-center px-3.5 pb-2.5 pt-1">
        <span className="text-[10px] text-zinc-400 dark:text-zinc-500">
          ↩ 发送 · ⇧↩ 换行 · / 命令
        </span>
        <div className="flex-1" />
        <button
          type="button"
          onClick={send}
          disabled={!canSend}
          className={[
            'rounded px-3.5 py-1 text-[12px] font-medium text-white transition-colors',
            canSend
              ? 'bg-[#07c160] hover:bg-[#06ad55]'
              : 'cursor-not-allowed bg-[#07c160]/40',
          ].join(' ')}
        >
          {isSlashCommand ? '执行命令' : '发送'}
        </button>
      </div>
    </div>
  );
}
