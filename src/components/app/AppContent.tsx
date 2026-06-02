import { useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';

import CommandPalette from '../command-palette/CommandPalette';
import WeChatRail, { WeChatBottomBar, type WeChatTab } from '../wechat/WeChatRail';
import WeChatSidebar from '../wechat/WeChatSidebar';
import WeChatChatPane, { type WeChatChatPaneSession } from '../wechat/WeChatChatPane';
import WeChatContactsList from '../wechat/WeChatContactsList';
import WeChatDiscoverTab from '../wechat/WeChatDiscoverTab';
import WeChatMeTab from '../wechat/WeChatMeTab';
import WeChatNewSessionPopover from '../wechat/WeChatNewSessionPopover';
import WeChatAddContactDialog from '../wechat/WeChatAddContactDialog';
import type { Project } from '../../types/app';
import { useWebSocket } from '../../contexts/WebSocketContext';
import { PaletteOpsProvider, usePaletteOpsRegister } from '../../contexts/PaletteOpsContext';
import { useDeviceSettings } from '../../hooks/useDeviceSettings';
import { useSessionProtection } from '../../hooks/useSessionProtection';
import { useProjectsState } from '../../hooks/useProjectsState';
import { useIM } from '../../contexts/IMContext';
import { useAuth } from '../auth';
import { imToast } from '../../services/im/toast';

export default function AppContent() {
  return (
    <PaletteOpsProvider>
      <AppContentInner />
    </PaletteOpsProvider>
  );
}

function AppContentInner() {
  const navigate = useNavigate();
  const { sessionId } = useParams<{ sessionId?: string }>();
  const { t } = useTranslation('common');
  const { isMobile } = useDeviceSettings({ trackPWA: false });
  const { ws, sendMessage, latestMessage, isConnected, connectionStatus, reconnectAttempt, latencyMs, pingNow } = useWebSocket();
  const wasConnectedRef = useRef(false);

  // Edge-transient connection toast: pop a banner only on the transitions
  // (dropped / restored). The durable state lives in the 我-tab indicator.
  const prevStatusRef = useRef(connectionStatus);
  const wasOnlineRef = useRef(false);
  useEffect(() => {
    const prev = prevStatusRef.current;
    if (prev === connectionStatus) return;
    prevStatusRef.current = connectionStatus;
    if (connectionStatus === 'online') {
      if (wasOnlineRef.current) imToast('已重新连接', 'info');
      wasOnlineRef.current = true;
    } else if (prev === 'online') {
      imToast(connectionStatus === 'offline' ? '网络已断开' : '连接断开，正在重连…', 'error');
    }
  }, [connectionStatus]);

  const {
    activeSessions,
    processingSessions,
    markSessionAsActive,
    markSessionAsInactive,
    markSessionAsProcessing,
    markSessionAsNotProcessing,
  } = useSessionProtection();

  const {
    selectedProject,
    selectedSession,
    activeTab,
    sidebarOpen,
    isLoadingProjects,
    externalMessageUpdate,
    newSessionTrigger,
    setActiveTab,
    setSidebarOpen,
    setIsInputFocused,
    setShowSettings,
    openSettings,
    refreshProjectsSilently,
    sidebarSharedProps,
    handleNewSession,
  } = useProjectsState({
    sessionId,
    navigate,
    latestMessage,
    isMobile,
    activeSessions,
  });

  usePaletteOpsRegister({
    openSettings,
    refreshProjects: refreshProjectsSilently,
  });

  useEffect(() => {
    if (typeof navigator === 'undefined' || !('serviceWorker' in navigator)) {
      return undefined;
    }

    const handleServiceWorkerMessage = (event: MessageEvent) => {
      const message = event.data;
      if (!message || message.type !== 'notification:navigate') {
        return;
      }

      if (typeof message.provider === 'string' && message.provider.trim()) {
        localStorage.setItem('selected-provider', message.provider);
      }

      setActiveTab('chat');
      setSidebarOpen(false);
      void refreshProjectsSilently();

      if (typeof message.sessionId === 'string' && message.sessionId) {
        navigate(`/session/${message.sessionId}`);
        return;
      }

      navigate('/');
    };

    navigator.serviceWorker.addEventListener('message', handleServiceWorkerMessage);

    return () => {
      navigator.serviceWorker.removeEventListener('message', handleServiceWorkerMessage);
    };
  }, [navigate, refreshProjectsSilently, setActiveTab, setSidebarOpen]);

  // Permission recovery: query pending permissions on WebSocket reconnect or session change
  useEffect(() => {
    const isReconnect = isConnected && !wasConnectedRef.current;

    if (isReconnect) {
      wasConnectedRef.current = true;
    } else if (!isConnected) {
      wasConnectedRef.current = false;
    }

    if (isConnected && selectedSession?.id) {
      sendMessage({
        type: 'get-pending-permissions',
        sessionId: selectedSession.id
      });
    }
  }, [isConnected, selectedSession?.id, sendMessage]);

  // Adjust the app container to stay above the virtual keyboard on iOS Safari.
  // On Chrome for Android the layout viewport already shrinks when the keyboard opens,
  // so inset-0 adjusts automatically. On iOS the layout viewport stays full-height and
  // the keyboard overlays it — we use the Visual Viewport API to track keyboard height
  // and apply it as a CSS variable that shifts the container's bottom edge up.
  useEffect(() => {
    const vv = window.visualViewport;
    if (!vv) return;
    const update = () => {
      // Only resize matters — keyboard open/close changes vv.height.
      // Do NOT listen to scroll: on iOS Safari, scrolling content changes
      // vv.offsetTop which would make --keyboard-height fluctuate during
      // normal scrolling, causing the container to bounce up and down.
      const kb = Math.max(0, window.innerHeight - vv.height);
      document.documentElement.style.setProperty('--keyboard-height', `${kb}px`);
    };
    vv.addEventListener('resize', update);
    return () => vv.removeEventListener('resize', update);
  }, []);

  // WeChat-style rail tab. Note: this is a Claude Code CLI client styled
  // after WeChat, not an actual WeChat clone — so 通讯录/发现/我 are framed
  // around Claude Code surfaces (projects-as-contacts, skills, settings).
  const [wechatTab, setWechatTab] = useState<WeChatTab>('chats');
  const { user } = useAuth();

  // On mobile we render a single-pane stack: list view OR chat view, never
  // both. Tapping a row sets this to true; the chat header's back arrow sets
  // it back to false. This decouples the UX from `selectedSession`, which we
  // KEEP set after going back so re-opening the chat is fast.
  const [mobileShowChat, setMobileShowChat] = useState(false);

  // "新建会话" popover + "添加联系人" wizard, and the pending new-session context
  // (a chosen contact for which no session id exists yet — created on first send).
  const [newChatOpen, setNewChatOpen] = useState(false);
  const [wizardOpen, setWizardOpen] = useState(false);
  const [newSession, setNewSession] = useState<{
    projectId: string;
    projectPath: string | null;
    displayName: string;
  } | null>(null);

  // Per-conversation unread + red-dot come from the IM hub (cross-device
  // correct: reading on any device clears the dot everywhere). The conversation
  // id equals the session id, so this maps straight onto the sidebar.
  const { unreadByConversation, markRead, conversations: imConversations, resync } = useIM();

  // Sessions Claude is actively running / recently touched — drives the green
  // "online" dot and keeps them un-pruned in the list.
  const liveSessionIds = useMemo(
    () => new Set<string>([...activeSessions, ...processingSessions]),
    [activeSessions, processingSessions],
  );

  // Notification API — ask permission once. Best-effort; failures are silent.
  useEffect(() => {
    if (typeof Notification === 'undefined') return;
    if (Notification.permission === 'default') {
      void Notification.requestPermission();
    }
  }, []);

  // Listen for `complete` frames and bump per-session unread when the chat
  // pane for that session isn't currently visible. Also fire a browser
  // notification so the user gets pinged when the tab is in the background.
  useEffect(() => {
    if (!latestMessage || typeof latestMessage !== 'object') return;
    const msg = latestMessage as Record<string, unknown>;
    const kind = (msg.kind as string) || (msg.type as string) || '';
    const sid = (msg.sessionId as string) || (msg.newSessionId as string) || '';
    if (!sid) return;
    // The "foreground session" is the one whose chat pane is mounted AND
    // visible. On mobile, the chat is only visible when mobileShowChat is true.
    const isForeground =
      selectedSession?.id === sid &&
      wechatTab === 'chats' &&
      (!isMobile || mobileShowChat);

    if (kind === 'complete' && !isForeground) {
      // The red-dot/unread itself is driven by the IM hub (im:message frames).
      // Here we only fire a best-effort browser notification.
      // Look up the session display name for a nice notification body.
      let label = sid.slice(0, 8);
      for (const p of sidebarSharedProps.projects) {
        const s = p.sessions?.find((x) => x.id === sid);
        if (s) {
          label = String(s.summary ?? s.title ?? s.name ?? label);
          break;
        }
      }
      if (typeof Notification !== 'undefined' && Notification.permission === 'granted') {
        try {
          const n = new Notification(`Claude 在「${label}」中回复了`, {
            body: '点击切换到该会话',
            tag: `claude-${sid}`,
          });
          n.onclick = () => {
            window.focus();
            // Best-effort jump — find the project for this sid.
            for (const p of sidebarSharedProps.projects) {
              const s = p.sessions?.find((x) => x.id === sid);
              if (s) {
                sidebarSharedProps.onSessionSelect({ ...s, __projectId: p.projectId });
                navigate(`/session/${sid}`);
                setMobileShowChat(true);
                setWechatTab('chats');
                break;
              }
            }
            n.close();
          };
        } catch {
          // Some browsers / private modes throw — ignore.
        }
      }
    }
  }, [latestMessage, selectedSession?.id, wechatTab, isMobile, mobileShowChat, sidebarSharedProps, navigate]);

  const totalUnread = useMemo(
    () => Object.values(unreadByConversation).reduce((a, b) => a + b, 0),
    [unreadByConversation],
  );

  // Auto-clear the red dot for the conversation currently in the foreground:
  // if a reply arrives while you're viewing a chat, its unread should not light
  // up. Self-correcting regardless of im:message / complete frame ordering.
  useEffect(() => {
    const sid = selectedSession?.id;
    if (!sid) return;
    const foreground = wechatTab === 'chats' && (!isMobile || mobileShowChat);
    if (foreground && (unreadByConversation[sid] ?? 0) > 0) {
      void markRead(sid);
    }
  }, [selectedSession?.id, wechatTab, isMobile, mobileShowChat, unreadByConversation, markRead]);

  // Adapt the selected session into the shape WeChatChatPane expects. We
  // tolerate selectedProject being null briefly (page reload at /session/:id
  // before projects are fetched) by falling back to a path scan.
  const chatPaneSession: WeChatChatPaneSession | null = useMemo(() => {
    // A pending new-session compose wins over any lingering selection so the
    // composer opens immediately when a contact is picked.
    if (newSession) {
      return {
        id: `new:${newSession.projectId}`,
        displayName: newSession.displayName,
        projectPath: newSession.projectPath,
        isNew: true,
      };
    }
    if (!selectedSession) {
      return null;
    }
    const displayName =
      selectedSession.summary ??
      selectedSession.title ??
      selectedSession.name ??
      selectedSession.id.slice(0, 8);
    // Find the project for this session even if it isn't yet "selected".
    let projectPath: string | null = null;
    if (selectedProject) {
      projectPath = selectedProject.fullPath ?? selectedProject.path ?? null;
    } else {
      for (const p of sidebarSharedProps.projects) {
        if (p.sessions?.some((s) => s.id === selectedSession.id)) {
          projectPath = p.fullPath ?? p.path ?? null;
          break;
        }
      }
    }
    return {
      id: selectedSession.id,
      displayName: String(displayName),
      projectPath,
    };
  }, [selectedProject, selectedSession, sidebarSharedProps.projects, newSession]);

  const handleSelectSession = (sessionId: string, projectId: string) => {
    // Selecting any existing session cancels a pending new-session compose.
    setNewSession(null);
    // Reuse the project state hook's existing flow — it walks `projects` to
    // find the session and updates selectedProject/selectedSession.
    const project = sidebarSharedProps.projects.find((p) => p.projectId === projectId);
    const session = project?.sessions?.find((s) => s.id === sessionId);
    if (session) {
      // Tag the session with __projectId so the existing handler knows which
      // project owns it (matches the path the sidebar normally takes).
      sidebarSharedProps.onSessionSelect({ ...session, __projectId: projectId });
    }
    navigate(`/session/${sessionId}`);
    // Mark the conversation read (clears the dot here + broadcasts to other devices).
    void markRead(sessionId);
    if (isMobile) setMobileShowChat(true);
  };

  // The sidebar "+" opens the contact picker (发起会话). Picking a contact
  // starts a fresh chat in that project; the session id is assigned by the
  // server on the first send (session_created), which we adopt below.
  const handleStartNewSession = () => {
    setNewChatOpen(true);
  };

  const handlePickContact = (project: Project) => {
    setNewChatOpen(false);
    setNewSession({
      projectId: project.projectId,
      projectPath: project.fullPath ?? project.path ?? null,
      displayName: project.displayName ?? project.fullPath ?? '新会话',
    });
    navigate('/');
    if (isMobile) setMobileShowChat(true);
  };

  // Adopt the server-assigned id once a new session is created from the
  // new-session composer, then drop out of new-session mode.
  useEffect(() => {
    if (!newSession || !latestMessage || typeof latestMessage !== 'object') return;
    const msg = latestMessage as Record<string, unknown>;
    const kind = (msg.kind as string) || (msg.type as string) || '';
    const newId =
      (msg.newSessionId as string) ||
      (kind === 'session_created' ? (msg.sessionId as string) : '');
    if (!newId) return;
    setNewSession(null);
    void refreshProjectsSilently();
    navigate(`/session/${newId}`);
    void markRead(newId);
  }, [latestMessage, newSession, navigate, refreshProjectsSilently, markRead]);

  // Chats tab content: WeChat-style 2-column inside the right area
  // (sidebar list + chat pane). On mobile we collapse to a single-pane stack
  // where tapping a session pushes the chat view over the list.
  const chatLayout = (
    <div
      className={[
        'flex min-w-0 flex-1',
        // On mobile, pin the layout to exactly the viewport width and clip
        // any horizontal overflow so long URLs / paths inside bubbles can't
        // create a scroll axis.
        isMobile ? 'w-screen overflow-x-hidden' : '',
      ].join(' ')}
    >
      {(!isMobile || !mobileShowChat) && (
        <div className={isMobile ? 'flex w-full flex-col' : 'h-full w-72 flex-shrink-0 border-r border-border/50'}>
          <WeChatSidebar
            projects={sidebarSharedProps.projects}
            selectedSessionId={selectedSession?.id ?? null}
            onSelectSession={handleSelectSession}
            onNewSession={handleStartNewSession}
            onRefresh={resync}
            unreadBySession={unreadByConversation}
            imConversations={imConversations}
            liveSessionIds={liveSessionIds}
          />
        </div>
      )}

      {(!isMobile || mobileShowChat) && (
        <div className="flex min-w-0 flex-1 flex-col overflow-x-hidden">
          <WeChatChatPane
            session={chatPaneSession}
            isMobile={isMobile}
            onMenuClick={isMobile ? () => {
              // On mobile, back = drop out of chat detail. We KEEP
              // `selectedSession` around so re-tapping the row is instant.
              setMobileShowChat(false);
            } : undefined}
          />
        </div>
      )}
    </div>
  );

  // Non-chat tabs.
  const tabContent = (() => {
    if (wechatTab === 'chats') {
      return chatLayout;
    }
    if (wechatTab === 'contacts') {
      // Contacts = sessions-as-contacts, grouped by project. Reuses the
      // same selection flow as the chats tab so picking a contact opens
      // the chat pane on the right.
      return (
        <div className="flex min-w-0 flex-1">
          <div className={isMobile ? 'flex w-full flex-col' : 'h-full w-72 flex-shrink-0 border-r border-border/50'}>
            <WeChatContactsList
              projects={sidebarSharedProps.projects}
              selectedSessionId={selectedSession?.id ?? null}
              onSelectSession={handleSelectSession}
              onAddContact={() => setWizardOpen(true)}
              imConversations={imConversations}
              liveSessionIds={liveSessionIds}
            />
          </div>
          {!isMobile && (
            <div className="flex min-w-0 flex-1 flex-col">
              <WeChatChatPane session={chatPaneSession} />
            </div>
          )}
        </div>
      );
    }
    if (wechatTab === 'discover') {
      return (
        <WeChatDiscoverTab
          isMobile={isMobile}
          selectedSessionId={selectedSession?.id ?? null}
          onInsertIntoComposer={(text) => {
            // Switch to the chats tab and prepend the picked command into the
            // current session's draft. The composer reads `draft` from local
            // state in WeChatChatPane — we route via a CustomEvent so we don't
            // have to lift draft state to the parent.
            setWechatTab('chats');
            window.dispatchEvent(new CustomEvent('wechat:insert-into-composer', { detail: { text } }));
          }}
        />
      );
    }
    // me tab
    return (
      <WeChatMeTab
        connectionStatus={connectionStatus}
        reconnectAttempt={reconnectAttempt}
        latencyMs={latencyMs}
        onPing={pingNow}
        isMobile={isMobile}
        onLogout={() => {
          // After logout the AuthContext flips and ProtectedRoute will mount
          // LoginForm; we don't need to do anything else here.
        }}
      />
    );
  })();

  return (
    <div
      className="fixed inset-0 flex bg-background"
      style={{
        // Keep app content clear of the notch / Dynamic Island (top) and the
        // landscape notch (left/right). On non-notched devices and desktop these
        // env() values resolve to 0, so this is a no-op there. We apply the inset
        // directly here rather than relying on the legacy `body.pwa-mode .fixed.inset-0`
        // rule, because the WeChat shell never mounts the old Sidebar that toggles
        // that class — so that rule would never fire.
        paddingTop: 'env(safe-area-inset-top)',
        paddingLeft: 'env(safe-area-inset-left)',
        paddingRight: 'env(safe-area-inset-right)',
        bottom: 'var(--keyboard-height, 0px)',
      }}
    >
      {/* Desktop ≥768px: vertical rail on the left.
          Mobile: bottom bar — placed at the end of the column. */}
      {!isMobile && (
        <WeChatRail
          active={wechatTab}
          onSelect={setWechatTab}
          username={user?.username ?? undefined}
          onAvatarClick={() => setWechatTab('me')}
          unreadCount={totalUnread}
        />
      )}

      {isMobile ? (
        <div className="flex min-w-0 flex-1 flex-col">
          <div className="flex min-h-0 flex-1 overflow-hidden">{tabContent}</div>
          {/* Hide the bottom bar while a chat is open so the conversation
              owns the full screen. Tapping the back arrow in the chat header
              clears `chatPaneSession` and brings the bar back. */}
          {!mobileShowChat && (
            <WeChatBottomBar
              active={wechatTab}
              onSelect={setWechatTab}
              unreadCount={totalUnread}
            />
          )}
        </div>
      ) : (
        tabContent
      )}

      {newChatOpen && (
        <WeChatNewSessionPopover
          projects={sidebarSharedProps.projects}
          onPickContact={handlePickContact}
          onAddContact={() => {
            setNewChatOpen(false);
            setWizardOpen(true);
          }}
          onClose={() => setNewChatOpen(false)}
        />
      )}

      {wizardOpen && (
        <WeChatAddContactDialog
          onClose={() => setWizardOpen(false)}
          onCreated={() => {
            void refreshProjectsSilently();
          }}
        />
      )}

      <CommandPalette
        selectedProject={selectedProject}
        onStartNewChat={handleNewSession}
        onOpenSettings={() => openSettings()}
        onShowTab={setActiveTab}
      />
    </div>
  );
}
