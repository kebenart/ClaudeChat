import { useCallback, useEffect, useMemo, useState } from 'react';

import {
  fetchBlacklist,
  postBlacklist,
  deleteBlacklist,
  postState,
} from '../../services/im/api';
import { imToast } from '../../services/im/toast';
import type { WireConversation } from '../../services/im/protocol';

// MARK: - useSessionMeta
//
// SERVER-SYNCED per-conversation meta (pin / mute / fold / note) + a path
// blacklist. Pin/mute/fold/note are read from the IM-hub conversation DTOs
// (passed in, kept fresh by the parent's /sync) and written via the IM API, so
// every client — web, iOS, macOS — agrees. The blacklist is fetched from the
// server and refreshed on focus + after each change. (Previously all of this
// lived in this browser's localStorage and diverged across clients.)

type StringSet = Set<string>;
type StringMap = Record<string, string>;

export interface SessionMeta {
  pinned: StringSet;
  muted: StringSet;
  folded: StringSet;
  blacklist: StringSet;
  notes: StringMap;
  isPinned: (sessionId: string) => boolean;
  isMuted: (sessionId: string) => boolean;
  isFolded: (sessionId: string) => boolean;
  isDeleted: (sessionId: string) => boolean;
  isPathBlacklisted: (path: string | null | undefined) => boolean;
  noteOf: (sessionId: string) => string;
  togglePin: (sessionId: string) => void;
  toggleMute: (sessionId: string) => void;
  toggleFold: (sessionId: string) => void;
  toggleBlacklist: (path: string) => void;
  setNote: (sessionId: string, newName: string) => void;
  /** WeChat-style delete: hide on every client (resurrected on a new message). */
  deleteSession: (sessionId: string) => void;
}

type Override = { isPinned?: boolean; isMuted?: boolean; isFolded?: boolean; isDeleted?: boolean; note?: string | null };

export function useSessionMeta(conversations: WireConversation[] = []): SessionMeta {
  const byId = useMemo(() => new Map(conversations.map((c) => [c.id, c])), [conversations]);

  // Optimistic local overrides: a delete/fold/pin/mute/rename reflects INSTANTLY.
  // The web has no guaranteed live im:poke-driven re-render, so without this the
  // row only changed after a manual reload. Each override is dropped once the
  // server-synced value catches up (the reconcile effect below).
  const [overrides, setOverrides] = useState<Record<string, Override>>({});
  const setOverride = useCallback(
    (id: string, patch: Override) => setOverrides((p) => ({ ...p, [id]: { ...p[id], ...patch } })),
    [],
  );
  // Roll a single optimistic field back to its prior value when the server
  // rejects the mutation (so a failed pin/mute/delete/rename doesn't "stick"
  // locally forever while never syncing). prev === undefined drops the field
  // entirely, falling back to the server DTO.
  const revertOverride = useCallback(
    <K extends keyof Override>(id: string, key: K, prev: Override[K] | undefined) => {
      setOverrides((p) => {
        const cur: Override = { ...(p[id] ?? {}) };
        if (prev === undefined) delete cur[key];
        else cur[key] = prev;
        const next = { ...p };
        if (Object.keys(cur).length) next[id] = cur;
        else delete next[id];
        return next;
      });
    },
    [],
  );

  // Derive the sets/maps from the server DTOs, with optimistic overrides applied.
  const { pinned, muted, folded, deleted, notes } = useMemo(() => {
    const p = new Set<string>();
    const m = new Set<string>();
    const f = new Set<string>();
    const d = new Set<string>();
    const n: StringMap = {};
    const apply = (id: string, sPin: boolean, sMute: boolean, sFold: boolean, sDel: boolean, sNote: string | null | undefined) => {
      const o = overrides[id] ?? {};
      if (o.isPinned ?? sPin) p.add(id);
      if (o.isMuted ?? sMute) m.add(id);
      if (o.isFolded ?? sFold) f.add(id);
      if (o.isDeleted ?? sDel) d.add(id);
      const nt = (o.note !== undefined ? o.note : sNote)?.trim();
      if (nt) n[id] = nt;
    };
    for (const c of conversations) apply(c.id, !!c.isPinned, !!c.isMuted, !!c.isFolded, !!c.isDeleted, c.note);
    for (const id of Object.keys(overrides)) if (!byId.has(id)) apply(id, false, false, false, false, undefined);
    return { pinned: p, muted: m, folded: f, deleted: d, notes: n };
  }, [conversations, overrides, byId]);

  // Drop each override once the server-synced value matches it.
  useEffect(() => {
    setOverrides((prev) => {
      const next: Record<string, Override> = {};
      let changed = false;
      for (const [id, o] of Object.entries(prev)) {
        const c = byId.get(id);
        if (!c) { next[id] = o; continue; }
        const no: Override = {};
        if (o.isPinned !== undefined && o.isPinned !== !!c.isPinned) no.isPinned = o.isPinned;
        if (o.isMuted !== undefined && o.isMuted !== !!c.isMuted) no.isMuted = o.isMuted;
        if (o.isFolded !== undefined && o.isFolded !== !!c.isFolded) no.isFolded = o.isFolded;
        if (o.isDeleted !== undefined && o.isDeleted !== !!c.isDeleted) no.isDeleted = o.isDeleted;
        if (o.note !== undefined && o.note !== (c.note ?? null)) no.note = o.note;
        if (Object.keys(no).length) next[id] = no;
        if (Object.keys(no).length !== Object.keys(o).length) changed = true;
      }
      return changed ? next : prev;
    });
  }, [byId]);

  // Blacklist lives only on the server; mirror it locally + refresh on focus and
  // on any im:poke (broadcast after a blacklist change on another device).
  const [blacklist, setBlacklist] = useState<StringSet>(new Set());
  useEffect(() => {
    let cancelled = false;
    const load = () => {
      void fetchBlacklist().then((paths) => {
        if (!cancelled) setBlacklist(new Set(paths));
      });
    };
    load();
    window.addEventListener('focus', load);
    window.addEventListener('im:poke', load);
    return () => {
      cancelled = true;
      window.removeEventListener('focus', load);
      window.removeEventListener('im:poke', load);
    };
  }, []);

  const togglePin = useCallback(
    (id: string) => {
      const prev = overrides[id]?.isPinned;
      const v = !(prev ?? byId.get(id)?.isPinned ?? false);
      setOverride(id, { isPinned: v });
      postState(id, { isPinned: v }).catch((err) => {
        console.error('IM pin sync failed', err);
        revertOverride(id, 'isPinned', prev);
        imToast('置顶未同步,请检查网络');
      });
    },
    [byId, overrides, setOverride, revertOverride],
  );
  const toggleMute = useCallback(
    (id: string) => {
      const prev = overrides[id]?.isMuted;
      const v = !(prev ?? byId.get(id)?.isMuted ?? false);
      setOverride(id, { isMuted: v });
      postState(id, { isMuted: v }).catch((err) => {
        console.error('IM mute sync failed', err);
        revertOverride(id, 'isMuted', prev);
        imToast('静音未同步,请检查网络');
      });
    },
    [byId, overrides, setOverride, revertOverride],
  );
  const toggleFold = useCallback(
    (id: string) => {
      const prev = overrides[id]?.isFolded;
      const v = !(prev ?? byId.get(id)?.isFolded ?? false);
      setOverride(id, { isFolded: v });
      postState(id, { isFolded: v }).catch((err) => {
        console.error('IM fold sync failed', err);
        revertOverride(id, 'isFolded', prev);
        imToast('折叠未同步,请检查网络');
      });
    },
    [byId, overrides, setOverride, revertOverride],
  );
  const setNote = useCallback(
    (id: string, newName: string) => {
      const prev = overrides[id]?.note;
      const v = newName.trim() || null;
      setOverride(id, { note: v });
      postState(id, { note: v }).catch((err) => {
        console.error('IM note sync failed', err);
        revertOverride(id, 'note', prev);
        imToast('备注名未同步,请检查网络');
      });
    },
    [overrides, setOverride, revertOverride],
  );
  const deleteSession = useCallback(
    (id: string) => {
      const prev = overrides[id]?.isDeleted;
      setOverride(id, { isDeleted: true });
      postState(id, { isDeleted: true }).catch((err) => {
        console.error('IM delete sync failed', err);
        revertOverride(id, 'isDeleted', prev);
        imToast('删除未同步,请检查网络');
      });
    },
    [overrides, setOverride, revertOverride],
  );

  const toggleBlacklist = useCallback(
    (path: string) => {
      const p = path.trim();
      if (!p) return;
      const has = blacklist.has(p);
      (has ? deleteBlacklist(p) : postBlacklist(p))
        .then((paths) => setBlacklist(new Set(paths)))
        .catch((err) => {
          console.error('IM blacklist sync failed', err);
          imToast('黑名单未同步,请检查网络');
        });
    },
    [blacklist],
  );

  const isPinned = useCallback((id: string) => pinned.has(id), [pinned]);
  const isMuted = useCallback((id: string) => muted.has(id), [muted]);
  const isFolded = useCallback((id: string) => folded.has(id), [folded]);
  const isDeleted = useCallback((id: string) => deleted.has(id), [deleted]);
  const noteOf = useCallback((id: string) => notes[id]?.trim() ?? '', [notes]);
  const isPathBlacklisted = useCallback(
    (path: string | null | undefined) => {
      if (!path) return false;
      for (const p of blacklist) {
        if (path === p || path.startsWith(p + '/')) return true;
      }
      return false;
    },
    [blacklist],
  );

  return {
    pinned, muted, folded, blacklist, notes,
    isPinned, isMuted, isFolded, isDeleted, isPathBlacklisted, noteOf,
    togglePin, toggleMute, toggleFold, toggleBlacklist, setNote, deleteSession,
  };
}
