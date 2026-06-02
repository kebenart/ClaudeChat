import { useEffect, useMemo, useState } from 'react';
import { CheckCircle2, Gift, X } from 'lucide-react';

import type { ChoiceCardContent, ChoiceQuestion } from '../../services/im/protocol';

// MARK: - WeChatChoiceCard
//
// A 红包-style interactive card for the two interactive Claude tools that pause
// a turn waiting on the user:
//   - AskUserQuestion → a vote-like poll (radio / checkbox per question).
//   - ExitPlanMode    → a plan with 同意 / 拒绝 buttons.
//
// Pending: a rounded, accent-tinted card ("Claude 需要你选择" / "Claude 提交了
// 一个计划" + a "点击查看" hint). Clicking opens a modal poll; submitting sends
// the answer over the chat WS (handled by the parent via onAnswer / onPlan) and
// optimistically dismisses. The server flips the same message to answered and it
// re-syncs.
//
// Answered: a dimmed, non-clickable RESOLVED card showing the `answer` summary.

interface Props {
  card: ChoiceCardContent;
  /** AskUserQuestion submit — answers maps question text → selected labels. */
  onAnswer?: (requestId: string, answers: Record<string, string[]>) => void;
  /** ExitPlanMode approve / reject. */
  onPlan?: (requestId: string, approve: boolean) => void;
}

const CARD_W_CLASS = 'w-full max-w-[320px]';
// Internal marker for the always-present "其他(自己填)" option — replaced by the
// typed text when the answer is built.
const OTHER_KEY = '__im_other__';

function cardTitle(card: ChoiceCardContent): string {
  return card.toolName === 'ExitPlanMode' ? 'Claude 提交了一个计划' : 'Claude 需要你选择';
}

export default function WeChatChoiceCard({ card, onAnswer, onPlan }: Props) {
  const [open, setOpen] = useState(false);
  // Locally dismiss after a submit so the card reads as resolved immediately —
  // the server will re-broadcast the answered card shortly after and replace it.
  const [submitted, setSubmitted] = useState(false);

  const answered = card.answered === true || submitted;

  // ── Answered (resolved) — dimmed, non-clickable summary card ────────────
  if (answered) {
    return (
      <div
        className={`${CARD_W_CLASS} overflow-hidden rounded-xl border border-zinc-200 bg-zinc-100/70 opacity-80 dark:border-zinc-700 dark:bg-zinc-800/60`}
      >
        <div className="flex items-center gap-2 px-3 py-2.5">
          <CheckCircle2 className="h-5 w-5 shrink-0 text-[#07c160]" />
          <div className="flex min-w-0 flex-col">
            <span className="truncate text-[12px] font-medium text-zinc-600 dark:text-zinc-300">
              {cardTitle(card)}
            </span>
            <span className="truncate text-[11px] text-zinc-500 dark:text-zinc-400">
              {card.answer ?? '已处理'}
            </span>
          </div>
        </div>
      </div>
    );
  }

  // ── Pending — clickable 红包-style card ─────────────────────────────────
  const hint =
    card.toolName === 'ExitPlanMode' ? '点击查看计划' : '点击作答';

  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        className={`${CARD_W_CLASS} group overflow-hidden rounded-xl border border-[#07c160]/40 bg-gradient-to-br from-[#07c160] to-[#06ad55] text-left shadow-sm transition-transform hover:scale-[1.01] active:scale-[0.99]`}
      >
        <div className="flex items-center gap-2.5 px-3 py-3">
          <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-white/20">
            <Gift className="h-5 w-5 text-white" />
          </div>
          <div className="flex min-w-0 flex-col">
            <span className="truncate text-[13px] font-semibold text-white">
              {cardTitle(card)}
            </span>
            <span className="truncate text-[11px] text-white/85">{hint}</span>
          </div>
        </div>
        <div className="bg-black/10 px-3 py-1 text-[10px] text-white/80">
          {card.toolName === 'ExitPlanMode' ? '计划待确认' : '互动选择'}
        </div>
      </button>

      {open && (
        <ChoiceModal
          card={card}
          onClose={() => setOpen(false)}
          onSubmitAnswers={(answers) => {
            onAnswer?.(card.requestId, answers);
            setSubmitted(true);
            setOpen(false);
          }}
          onSubmitPlan={(approve) => {
            onPlan?.(card.requestId, approve);
            setSubmitted(true);
            setOpen(false);
          }}
        />
      )}
    </>
  );
}

// ────────────────────────────────────────────────────────────────────────────
// Poll / plan modal
// ────────────────────────────────────────────────────────────────────────────

interface ModalProps {
  card: ChoiceCardContent;
  onClose: () => void;
  onSubmitAnswers: (answers: Record<string, string[]>) => void;
  onSubmitPlan: (approve: boolean) => void;
}

function ChoiceModal({ card, onClose, onSubmitAnswers, onSubmitPlan }: ModalProps) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);

  const isPlan = card.toolName === 'ExitPlanMode';
  const questions = useMemo<ChoiceQuestion[]>(() => card.questions ?? [], [card.questions]);

  // selections[questionIndex] = Set of selected labels.
  const [selections, setSelections] = useState<Record<number, string[]>>({});
  // Free text typed into the always-present "其他" option, per question index.
  const [customText, setCustomText] = useState<Record<number, string>>({});

  const toggle = (qIdx: number, label: string, multi: boolean) => {
    setSelections((prev) => {
      const cur = prev[qIdx] ?? [];
      if (multi) {
        const next = cur.includes(label) ? cur.filter((l) => l !== label) : [...cur, label];
        return { ...prev, [qIdx]: next };
      }
      // single-select: replace
      return { ...prev, [qIdx]: [label] };
    });
  };

  // Selected labels for a question, with the "其他" marker resolved to its typed
  // text (dropped when empty).
  const resolvedLabels = (qIdx: number): string[] =>
    (selections[qIdx] ?? []).flatMap((label) => {
      if (label !== OTHER_KEY) return [label];
      const t = (customText[qIdx] ?? '').trim();
      return t ? [t] : [];
    });

  // Require at least one resolved label per question before enabling 提交.
  const allAnswered = !isPlan && questions.every((_, idx) => resolvedLabels(idx).length > 0);

  const submitAnswers = () => {
    const answers: Record<string, string[]> = {};
    questions.forEach((q, idx) => {
      answers[q.question] = resolvedLabels(idx);
    });
    onSubmitAnswers(answers);
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/30 p-4"
      onClick={onClose}
    >
      <div
        className="flex max-h-[80vh] w-full max-w-[480px] flex-col overflow-hidden rounded-lg border border-[var(--wc-border)] bg-[var(--wc-bg-app)] shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between border-b border-[var(--wc-border)] px-4 py-2.5">
          <span className="flex items-center gap-1.5 text-[13px] font-medium text-[var(--wc-text-primary)]">
            <Gift className="h-4 w-4 text-[#07c160]" />
            {isPlan ? 'Claude 提交了一个计划' : 'Claude 需要你选择'}
          </span>
          <button
            type="button"
            onClick={onClose}
            className="rounded p-1 text-[var(--wc-text-secondary)] hover:bg-[var(--wc-item-hover)]"
            aria-label="关闭"
          >
            <X className="h-4 w-4" />
          </button>
        </div>

        {/* Body */}
        <div className="flex-1 overflow-auto px-4 py-3">
          {isPlan ? (
            <pre className="whitespace-pre-wrap break-words text-[13px] leading-relaxed text-[var(--wc-text-primary)]">
              {card.plan ?? '(无计划内容)'}
            </pre>
          ) : (
            <div className="flex flex-col gap-4">
              {questions.map((q, qIdx) => {
                const multi = q.multiSelect === true;
                const selected = selections[qIdx] ?? [];
                return (
                  <div key={qIdx} className="flex flex-col gap-2">
                    {q.header && (
                      <div className="text-[11px] font-medium uppercase tracking-wider text-[var(--wc-text-secondary)]">
                        {q.header}
                      </div>
                    )}
                    <div className="text-[13px] font-medium text-[var(--wc-text-primary)]">
                      {q.question}
                    </div>
                    <div className="flex flex-col gap-1.5">
                      {q.options.map((opt) => {
                        const isSel = selected.includes(opt.label);
                        return (
                          <button
                            key={opt.label}
                            type="button"
                            onClick={() => toggle(qIdx, opt.label, multi)}
                            className={[
                              'flex w-full items-start gap-2.5 rounded-lg border px-3 py-2 text-left transition-colors',
                              isSel
                                ? 'border-[#07c160] bg-[#07c160]/10'
                                : 'border-[var(--wc-border)] hover:bg-[var(--wc-item-hover)]',
                            ].join(' ')}
                          >
                            {/* radio / checkbox indicator */}
                            <span
                              className={[
                                'mt-0.5 flex h-4 w-4 shrink-0 items-center justify-center border',
                                multi ? 'rounded' : 'rounded-full',
                                isSel
                                  ? 'border-[#07c160] bg-[#07c160] text-white'
                                  : 'border-zinc-400 text-transparent',
                              ].join(' ')}
                            >
                              {isSel && <CheckCircle2 className="h-3 w-3" />}
                            </span>
                            <span className="flex min-w-0 flex-col">
                              <span className="text-[13px] text-[var(--wc-text-primary)]">
                                {opt.label}
                              </span>
                              {opt.description && (
                                <span className="text-[11px] text-[var(--wc-text-secondary)]">
                                  {opt.description}
                                </span>
                              )}
                            </span>
                          </button>
                        );
                      })}
                      {/* Always-available "其他" → reveals a free-text input. */}
                      {(() => {
                        const otherSel = selected.includes(OTHER_KEY);
                        return (
                          <>
                            <button
                              type="button"
                              onClick={() => toggle(qIdx, OTHER_KEY, multi)}
                              className={[
                                'flex w-full items-start gap-2.5 rounded-lg border px-3 py-2 text-left transition-colors',
                                otherSel
                                  ? 'border-[#07c160] bg-[#07c160]/10'
                                  : 'border-[var(--wc-border)] hover:bg-[var(--wc-item-hover)]',
                              ].join(' ')}
                            >
                              <span
                                className={[
                                  'mt-0.5 flex h-4 w-4 shrink-0 items-center justify-center border',
                                  multi ? 'rounded' : 'rounded-full',
                                  otherSel
                                    ? 'border-[#07c160] bg-[#07c160] text-white'
                                    : 'border-zinc-400 text-transparent',
                                ].join(' ')}
                              >
                                {otherSel && <CheckCircle2 className="h-3 w-3" />}
                              </span>
                              <span className="text-[13px] text-[var(--wc-text-primary)]">其他(自己填)</span>
                            </button>
                            {otherSel && (
                              <input
                                type="text"
                                autoFocus
                                value={customText[qIdx] ?? ''}
                                onChange={(e) => setCustomText((p) => ({ ...p, [qIdx]: e.target.value }))}
                                placeholder="输入你的答案…"
                                className="ml-6 rounded-md border border-[var(--wc-border)] bg-[var(--wc-bg-app)] px-2.5 py-1.5 text-[13px] text-[var(--wc-text-primary)] outline-none focus:border-[#07c160]"
                              />
                            )}
                          </>
                        );
                      })()}
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="flex items-center justify-end gap-2 border-t border-[var(--wc-border)] px-4 py-2.5">
          {isPlan ? (
            <>
              <button
                type="button"
                onClick={() => onSubmitPlan(false)}
                className="rounded-md px-3 py-1.5 text-[12px] font-medium text-zinc-700 hover:bg-[var(--wc-item-hover)] dark:text-zinc-300"
              >
                拒绝
              </button>
              <button
                type="button"
                onClick={() => onSubmitPlan(true)}
                className="rounded-md bg-[#07c160] px-3.5 py-1.5 text-[12px] font-medium text-white hover:bg-[#06ad55]"
              >
                同意
              </button>
            </>
          ) : (
            <button
              type="button"
              disabled={!allAnswered}
              onClick={submitAnswers}
              className="rounded-md bg-[#07c160] px-4 py-1.5 text-[12px] font-medium text-white hover:bg-[#06ad55] disabled:cursor-not-allowed disabled:opacity-40"
            >
              提交
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
