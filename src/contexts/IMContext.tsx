import { createContext, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';

import { useWebSocket } from '@/contexts/WebSocketContext';
import { InMemoryImStore } from '@/services/im/store';
import type { ImStore } from '@/services/im/store';
import { applySync, applyFrame, computeUnread } from '@/services/im/syncEngine';
import { fetchSync, postRead } from '@/services/im/api';
import { imToast } from '@/services/im/toast';
import IMToast from '@/components/wechat/IMToast';
import { getDeviceId } from '@/services/im/deviceId';
import { isImFrame } from '@/services/im/protocol';
import type {
  ImConversationProgress,
  WireConversation,
  WireMessage,
} from '@/services/im/protocol';

interface IMContextValue {
  conversations: WireConversation[];
  unreadByConversation: Record<string, number>;
  /** Live per-conversation processing progress from im:status frames. An entry
   *  exists only while that conversation is processing; cleared on the terminal
   *  isProcessing:false frame. */
  progressByConversation: Record<string, ImConversationProgress>;
  getMessages: (conversationId: string) => Promise<WireMessage[]>;
  markRead: (conversationId: string) => Promise<void>;
  /** User-triggered full re-sync (sidebar refresh button). */
  resync: () => Promise<void>;
}

const IMContext = createContext<IMContextValue | null>(null);

// How many recent messages per conversation to pull on a COLD start (empty
// store, cursor === 0). The server returns only the last N per conversation and
// jumps our cursor to its max rev, so we skip streaming the entire history
// (~thousands of rows) into the in-memory store. Older history lazy-loads per
// conversation via fetchMessages / the transcript view. Mirrors iOS
// (IOSAppModel.coldStartRecent). WARM starts (cursor > 0) keep paging
// incrementally from the stored cursor.
const COLD_START_RECENT = 50;

// Coalesce window for bursty im:poke frames. During a streaming Claude reply the
// server emits one im:poke per tool step (many per second). Without this every
// poke fired its own /sync + full sidebar re-render — a request storm. We
// instead collapse a burst into a single trailing /sync. Mirrors macOS
// scheduleRefresh (250ms) / iOS (800ms).
const POKE_DEBOUNCE_MS = 400;

type ImSyncController = {
  inFlight: boolean;
  dirty: boolean;
  timer: number | null;
  run: () => Promise<void>;
  schedule: () => void;
};

export function IMProvider({ children }: { children: ReactNode }) {
  const { latestMessage, isConnected } = useWebSocket();
  // In-memory store (not IndexedDB): the conversation list + previews + read
  // cursors are re-synced fresh from the server on every load. Persisting them
  // locally repeatedly went stale across dev iterations and the IndexedDB
  // version upgrades could block on multiple tabs — the server is the single
  // source of truth, and a full /sync from cursor 0 is cheap.
  const storeRef = useRef<ImStore | null>(null);
  if (storeRef.current === null) storeRef.current = new InMemoryImStore();
  const deviceId = useMemo(() => getDeviceId(), []);

  const [conversations, setConversations] = useState<WireConversation[]>([]);
  const [unreadByConversation, setUnread] = useState<Record<string, number>>({});
  // Live per-conversation progress, driven purely by im:status frames (kept out
  // of the store — it's ephemeral turn state, not persisted history).
  const [progressByConversation, setProgress] = useState<
    Record<string, ImConversationProgress>
  >({});
  // Mutable mirror of progress so refresh() (a stable useRef closure) can read
  // the current value without being re-created on every progress change.
  const progressRef = useRef(progressByConversation);
  progressRef.current = progressByConversation;

  // Recompute the reactive snapshot from the store after any mutation.
  const refresh = useRef(async () => {
    const store = storeRef.current;
    if (!store) return;
    const [convs, unread] = await Promise.all([store.getConversations(), computeUnread(store)]);
    convs.sort(
      (a, b) => (b.isPinned ? 1 : 0) - (a.isPinned ? 1 : 0) || b.lastActivityAt - a.lastActivityAt
    );
    setConversations(convs);
    setUnread(unread);

    // Self-healing fallback for a stuck "执行了 N 个操作" row. It normally clears
    // on the one-shot im:status{isProcessing:false} frame, but that frame is
    // lost if we're mid-reconnect when a long turn ends — the reply then lands
    // via /sync (not a live frame) and the row sticks forever. So after every
    // sync, drop progress for any conversation whose newest stored message is
    // already an assistant reply (no turn can be in flight). An active turn
    // re-lights via the next im:status(true). Mirrors watchOS clearAnsweredThinking.
    const active = Object.keys(progressRef.current);
    if (active.length > 0) {
      const answered: string[] = [];
      for (const cid of active) {
        const msgs = await store.getMessages(cid);
        const last = msgs[msgs.length - 1];
        if (last && last.role === 'assistant') answered.push(cid);
      }
      if (answered.length > 0) {
        setProgress((prev) => {
          const next = { ...prev };
          for (const cid of answered) delete next[cid];
          return next;
        });
      }
    }
  }).current;

  // Incremental-sync controller — coalesces bursty im:poke frames into a single
  // trailing /sync, guards against overlapping in-flight syncs (a new poke
  // mid-flight just re-arms one more pass), and surfaces failures as a toast
  // instead of a silent console.error. `schedule()` is the debounced entry
  // point; `run()` forces an immediate pass (manual refresh / resync).
  const syncCtl = useRef<ImSyncController | null>(null);
  if (syncCtl.current === null) {
    const ctl: ImSyncController = {
      inFlight: false,
      dirty: false,
      timer: null,
      run: async () => {
        const store = storeRef.current;
        if (!store) return;
        if (ctl.inFlight) {
          ctl.dirty = true; // someone asked again mid-flight — do one more pass
          return;
        }
        ctl.inFlight = true;
        try {
          let since = await store.getCursor();
          for (;;) {
            const resp = await fetchSync(since);
            await applySync(store, resp);
            if (!resp.hasMore || resp.cursor <= since) break;
            since = resp.cursor;
          }
          await refresh();
          // Coalesced blacklist nudge: an im:poke can carry a cross-device
          // blacklist change (not on the conversation DTOs), so let
          // useSessionMeta refetch it — but only once per collapsed burst.
          window.dispatchEvent(new Event('im:poke'));
        } catch (err) {
          console.error('IM sync failed', err);
          imToast('同步失败,请检查网络');
        } finally {
          ctl.inFlight = false;
          if (ctl.dirty) {
            ctl.dirty = false;
            ctl.schedule();
          }
        }
      },
      schedule: () => {
        if (ctl.timer !== null) return; // a pass is already pending — collapse
        ctl.timer = window.setTimeout(() => {
          ctl.timer = null;
          void ctl.run();
        }, POKE_DEBOUNCE_MS);
      },
    };
    syncCtl.current = ctl;
  }

  // Per-conversation last-reported read seq — skip /read round-trips when the
  // seq is unchanged (markRead fires on every reload/onChange). Mirrors macOS
  // lastMarkedSeq.
  const lastMarkedSeq = useRef<Map<string, number>>(new Map());

  // Sync whenever the chat WebSocket is connected. The WS only connects with a
  // valid auth token, so this guarantees /sync runs AFTER login (fixes the
  // cold-login empty-sidebar case) and also re-syncs on every reconnect to
  // catch up on anything missed while offline.
  useEffect(() => {
    if (!isConnected) return;
    let cancelled = false;
    (async () => {
      const store = storeRef.current;
      if (!store) return;
      const startCursor = await store.getCursor();

      // Cold start (empty local store, cursor === 0): one request with
      // recent=N (since=0). The server caps to the last N messages per
      // conversation and returns its max rev as the new baseline cursor —
      // instead of looping the entire message history into the store.
      if (startCursor === 0) {
        const resp = await fetchSync(0, COLD_START_RECENT);
        if (cancelled) return;
        await applySync(store, resp);
        await refresh();
        return;
      }

      // Warm start (cursor > 0): page incrementally from the stored cursor.
      let since = startCursor;
      for (;;) {
        const resp = await fetchSync(since);
        if (cancelled) return;
        await applySync(store, resp);
        await refresh(); // surface each page as it lands
        // Defensive: stop if the server claims more but didn't advance the cursor.
        if (!resp.hasMore || resp.cursor <= since) break;
        since = resp.cursor;
      }
    })().catch((err) => {
      console.error('IM sync failed', err);
      imToast('同步失败,请检查网络');
    });
    return () => {
      cancelled = true;
    };
  }, [isConnected, refresh]);

  // Apply incoming WS frames.
  useEffect(() => {
    if (!latestMessage || !isImFrame(latestMessage)) return;
    const store = storeRef.current;
    if (!store) return;
    if (latestMessage.type === 'im:poke') {
      // Debounced + coalesced: a burst of pokes collapses into one /sync (which
      // also re-broadcasts the window 'im:poke' for the blacklist refetch).
      syncCtl.current?.schedule();
      return;
    }
    if (latestMessage.type === 'im:status') {
      // Richer-than-typing progress signal. Maintain a per-conversation entry
      // while processing; the terminal isProcessing:false frame removes it so
      // the typing row clears. Doesn't touch the store (ephemeral turn state).
      const { conversationId, isProcessing, toolCount, currentTool } = latestMessage;
      setProgress((prev) => {
        if (!isProcessing) {
          if (!(conversationId in prev)) return prev;
          const next = { ...prev };
          delete next[conversationId];
          return next;
        }
        return {
          ...prev,
          [conversationId]: {
            isProcessing: true,
            toolCount: toolCount ?? 0,
            currentTool: currentTool ?? null,
          },
        };
      });
      return;
    }
    // Fallback clear for the "正在输入… · 执行了 N 个操作" row: the only signal
    // that normally clears it is the one-shot im:status{isProcessing:false}
    // frame, which is lost if we're mid-reconnect when the long turn ends — the
    // row then sticks forever. An assistant message for a conversation means its
    // turn produced output, so clear that conversation's progress here too.
    if (latestMessage.type === 'im:message' && latestMessage.message?.role === 'assistant') {
      const cid = latestMessage.message.conversationId;
      setProgress((prev) => {
        if (!(cid in prev)) return prev;
        const next = { ...prev };
        delete next[cid];
        return next;
      });
    }

    (async () => {
      await applyFrame(store, latestMessage);
      await refresh();
    })().catch((err) => console.error('IM frame apply failed', err));
  }, [latestMessage, refresh]);

  const value = useMemo<IMContextValue>(
    () => ({
      conversations,
      unreadByConversation,
      progressByConversation,
      getMessages: (conversationId: string) =>
        storeRef.current ? storeRef.current.getMessages(conversationId) : Promise.resolve([]),
      markRead: async (conversationId: string) => {
        const store = storeRef.current;
        if (!store) return;
        const conv = (await store.getConversations()).find((c) => c.id === conversationId);
        const seq = conv?.lastSeq ?? 0;
        await store.setReadCursor(conversationId, deviceId, seq);
        await refresh();
        // Skip the /read POST if we already reported this exact seq — markRead
        // fires on every chat reload/onChange and would otherwise spam the
        // endpoint. Cache only updates on success so a failed post retries.
        if (lastMarkedSeq.current.get(conversationId) === seq) return;
        try {
          await postRead(conversationId, deviceId, seq); // broadcasts im:read → other devices clear
          lastMarkedSeq.current.set(conversationId, seq);
        } catch (err) {
          console.error('IM mark-read failed', err);
        }
      },
      resync: async () => {
        // Force an immediate incremental pass (the controller catches up from
        // the stored cursor and re-broadcasts the blacklist nudge).
        await syncCtl.current?.run();
      },
    }),
    [conversations, unreadByConversation, progressByConversation, deviceId, refresh]
  );

  return (
    <IMContext.Provider value={value}>
      {children}
      <IMToast />
    </IMContext.Provider>
  );
}

export function useIM(): IMContextValue {
  const ctx = useContext(IMContext);
  if (!ctx) throw new Error('useIM must be used within <IMProvider>');
  return ctx;
}
