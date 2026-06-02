import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react';

import { useAuth } from '../components/auth/context/AuthContext';
import { IS_PLATFORM } from '../constants/config';

import { computeBackoffDelay } from './connectionBackoff';

export type ConnectionStatus = 'online' | 'reconnecting' | 'offline';

type WebSocketContextType = {
  ws: WebSocket | null;
  sendMessage: (message: any) => void;
  latestMessage: any | null;
  isConnected: boolean;
  /** Three-state health: connected+healthy / retrying / device offline. */
  connectionStatus: ConnectionStatus;
  /** How many reconnect attempts since the last healthy connection (0 when online). */
  reconnectAttempt: number;
  /** Last measured WS round-trip latency in ms (ping→pong); null until the first sample / when offline. */
  latencyMs: number | null;
  /** Send an immediate ping to refresh `latencyMs` on demand. */
  pingNow: () => void;
};

const WebSocketContext = createContext<WebSocketContextType | null>(null);

// Heartbeat: send a {type:'ping'} every INTERVAL; the server replies {type:'pong'}
// (server/modules/websocket/services/chat-websocket.service.ts). Any inbound frame
// advances the liveness clock — if NOTHING arrives for DEAD_MS the socket is
// "假死" (server crashed without a clean close) and we force a reconnect.
const HEARTBEAT_INTERVAL_MS = 25000;
const HEARTBEAT_DEAD_MS = 35000;

export const useWebSocket = () => {
  const context = useContext(WebSocketContext);
  if (!context) {
    throw new Error('useWebSocket must be used within a WebSocketProvider');
  }
  return context;
};

const buildWebSocketUrl = (token: string | null, allowNoToken: boolean) => {
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  // Platform mode: Use same domain as the page (goes through proxy)
  if (IS_PLATFORM) return `${protocol}//${window.location.host}/ws`;
  // OSS mode w/ token: attach token to URL
  if (token) {
    return `${protocol}//${window.location.host}/ws?token=${encodeURIComponent(token)}`;
  }
  // DEV_AUTH_BYPASS: backend accepts no-token connections — connect anyway.
  if (allowNoToken) {
    return `${protocol}//${window.location.host}/ws`;
  }
  return null;
};

const deviceOffline = () => typeof navigator !== 'undefined' && navigator.onLine === false;

const useWebSocketProviderState = (): WebSocketContextType => {
  const wsRef = useRef<WebSocket | null>(null);
  const unmountedRef = useRef(false); // Track if component is unmounted
  const hasConnectedRef = useRef(false); // Track if we've ever connected (to detect reconnects)
  const [latestMessage, setLatestMessage] = useState<any>(null);
  const [isConnected, setIsConnected] = useState(false);
  const [connectionStatus, setConnectionStatus] = useState<ConnectionStatus>('reconnecting');
  const [reconnectAttempt, setReconnectAttempt] = useState(0);
  const attemptRef = useRef(0); // mutable mirror of reconnectAttempt for the backoff schedule
  const reconnectTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const heartbeatRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const lastInboundRef = useRef(0); // Date.now() of the last frame received
  const pendingPingAtRef = useRef<number | null>(null); // Date.now() of the ping awaiting a pong
  const [latencyMs, setLatencyMs] = useState<number | null>(null);
  const { token, user } = useAuth();

  // When there's no token but the AuthContext has surfaced a `user`, we're in
  // DEV_AUTH_BYPASS mode (server skipped JWT). The backend still accepts
  // no-token WS upgrades in that mode, so we should connect.
  const allowNoToken = !token && Boolean(user);

  const stopHeartbeat = useCallback(() => {
    if (heartbeatRef.current) {
      clearInterval(heartbeatRef.current);
      heartbeatRef.current = null;
    }
  }, []);

  const startHeartbeat = useCallback((socket: WebSocket) => {
    stopHeartbeat();
    lastInboundRef.current = Date.now();
    heartbeatRef.current = setInterval(() => {
      if (socket.readyState !== WebSocket.OPEN) return;
      // No traffic at all for too long ⇒ assume the socket is dead and force a
      // reconnect (close() fires onclose → schedules a reconnect).
      if (Date.now() - lastInboundRef.current > HEARTBEAT_DEAD_MS) {
        console.warn('[WebSocket] heartbeat: no inbound frames — closing zombie socket');
        try { socket.close(); } catch { /* ignore */ }
        return;
      }
      try {
        pendingPingAtRef.current = Date.now();
        socket.send(JSON.stringify({ type: 'ping' }));
      } catch { /* ignore — next interval / onclose handles it */ }
    }, HEARTBEAT_INTERVAL_MS);
  }, [stopHeartbeat]);

  const connect = useCallback(() => {
    if (unmountedRef.current) return; // Prevent connection if unmounted
    if (deviceOffline()) {
      // No network path — don't burn attempts; the 'online' event will retry.
      setConnectionStatus('offline');
      return;
    }
    try {
      // Construct WebSocket URL
      const wsUrl = buildWebSocketUrl(token, allowNoToken);

      if (!wsUrl) {
        console.warn('No authentication token found for WebSocket connection');
        return;
      }

      const websocket = new WebSocket(wsUrl);
      // Stash the socket immediately so sendMessage() called between
      // CONNECTING and OPEN can at least find the reference. (We still gate
      // sending on readyState below.)
      wsRef.current = websocket;

      websocket.onopen = () => {
        setIsConnected(true);
        setConnectionStatus('online');
        attemptRef.current = 0;
        setReconnectAttempt(0);
        wsRef.current = websocket;
        startHeartbeat(websocket);
        if (hasConnectedRef.current) {
          // This is a reconnect — signal so components can catch up on missed messages
          setLatestMessage({ type: 'websocket-reconnected', timestamp: Date.now() });
        }
        hasConnectedRef.current = true;
      };

      websocket.onmessage = (event) => {
        lastInboundRef.current = Date.now();
        try {
          const data = JSON.parse(event.data);
          // Heartbeat reply — pure keepalive, don't propagate to consumers.
          // It also doubles as the latency probe: ping→pong round-trip time.
          if (data && data.type === 'pong') {
            if (pendingPingAtRef.current != null) {
              setLatencyMs(Math.max(0, Date.now() - pendingPingAtRef.current));
              pendingPingAtRef.current = null;
            }
            return;
          }
          setLatestMessage(data);
        } catch (error) {
          console.error('Error parsing WebSocket message:', error);
        }
      };

      websocket.onclose = () => {
        stopHeartbeat();
        setIsConnected(false);
        setLatencyMs(null);
        pendingPingAtRef.current = null;
        wsRef.current = null;

        if (unmountedRef.current) return; // Prevent reconnection if unmounted

        if (deviceOffline()) {
          // Device lost the network — wait for the 'online' event to retry
          // instead of spinning the backoff against a dead interface.
          setConnectionStatus('offline');
          return;
        }

        setConnectionStatus('reconnecting');
        const delay = computeBackoffDelay(attemptRef.current);
        attemptRef.current += 1;
        setReconnectAttempt(attemptRef.current);
        reconnectTimeoutRef.current = setTimeout(() => {
          if (unmountedRef.current) return;
          connect();
        }, delay);
      };

      websocket.onerror = (error) => {
        console.error('WebSocket error:', error);
      };

    } catch (error) {
      console.error('Error creating WebSocket connection:', error);
    }
  }, [token, allowNoToken, startHeartbeat, stopHeartbeat]);

  useEffect(() => {
    unmountedRef.current = false;
    connect();

    // Device network transitions: drop immediately to 'offline' so the UI
    // reflects reality, and reconnect the instant the network returns.
    const handleOnline = () => {
      attemptRef.current = 0;
      setReconnectAttempt(0);
      if (reconnectTimeoutRef.current) {
        clearTimeout(reconnectTimeoutRef.current);
        reconnectTimeoutRef.current = null;
      }
      if (!wsRef.current) connect();
    };
    const handleOffline = () => {
      setConnectionStatus('offline');
      setIsConnected(false);
      if (wsRef.current) {
        try { wsRef.current.close(); } catch { /* ignore */ }
      }
    };
    window.addEventListener('online', handleOnline);
    window.addEventListener('offline', handleOffline);

    return () => {
      unmountedRef.current = true;
      window.removeEventListener('online', handleOnline);
      window.removeEventListener('offline', handleOffline);
      stopHeartbeat();
      if (reconnectTimeoutRef.current) {
        clearTimeout(reconnectTimeoutRef.current);
      }
      if (wsRef.current) {
        wsRef.current.close();
      }
    };
  }, [connect, stopHeartbeat]);

  const sendMessage = useCallback((message: any) => {
    const socket = wsRef.current;
    if (socket && socket.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify(message));
      return;
    }
    if (socket && socket.readyState === WebSocket.CONNECTING) {
      console.warn('[WebSocket] still connecting — message dropped:', message?.type ?? message);
      throw new Error('WebSocket 正在连接中，请稍后重试');
    }
    console.warn('[WebSocket] not connected — message dropped:', message?.type ?? message);
    throw new Error('WebSocket 未连接');
  }, []);

  // On-demand latency probe — sends a ping immediately; the pong handler above
  // records the round-trip into latencyMs. No-op if the socket isn't open.
  const pingNow = useCallback(() => {
    const socket = wsRef.current;
    if (socket && socket.readyState === WebSocket.OPEN) {
      try {
        pendingPingAtRef.current = Date.now();
        socket.send(JSON.stringify({ type: 'ping' }));
      } catch { /* ignore */ }
    }
  }, []);

  const value: WebSocketContextType = useMemo(() =>
  ({
    ws: wsRef.current,
    sendMessage,
    latestMessage,
    isConnected,
    connectionStatus,
    reconnectAttempt,
    latencyMs,
    pingNow,
  }), [sendMessage, latestMessage, isConnected, connectionStatus, reconnectAttempt, latencyMs, pingNow]);

  return value;
};

export const WebSocketProvider = ({ children }: { children: React.ReactNode }) => {
  const webSocketData = useWebSocketProviderState();

  return (
    <WebSocketContext.Provider value={webSocketData}>
      {children}
    </WebSocketContext.Provider>
  );
};

export default WebSocketContext;
