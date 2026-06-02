import { useCallback, useEffect, useRef, useState } from 'react';
import { CLAUDE_MODELS } from '../../../../shared/modelConstants';
import type { PendingPermissionRequest, PermissionMode } from '../types/types';
import type { ProjectSession, LLMProvider } from '../../../types/app';

const PERMISSION_MODES: PermissionMode[] = ['default', 'auto', 'acceptEdits', 'bypassPermissions', 'plan'];

interface UseChatProviderStateArgs {
  selectedSession: ProjectSession | null;
}

export function useChatProviderState({ selectedSession }: UseChatProviderStateArgs) {
  const [permissionMode, setPermissionMode] = useState<PermissionMode>('default');
  const [pendingPermissionRequests, setPendingPermissionRequests] = useState<PendingPermissionRequest[]>([]);
  const [provider] = useState<LLMProvider>('claude');
  const [claudeModel, setClaudeModel] = useState<string>(() => {
    return localStorage.getItem('claude-model') || CLAUDE_MODELS.DEFAULT;
  });

  const lastProviderRef = useRef(provider);

  useEffect(() => {
    if (!selectedSession?.id) {
      return;
    }

    const savedMode = localStorage.getItem(`permissionMode-${selectedSession.id}`) as PermissionMode | null;
    setPermissionMode(savedMode && PERMISSION_MODES.includes(savedMode) ? savedMode : 'default');
  }, [selectedSession?.id]);

  useEffect(() => {
    if (lastProviderRef.current === provider) {
      return;
    }
    setPendingPermissionRequests([]);
    lastProviderRef.current = provider;
  }, [provider]);

  useEffect(() => {
    setPendingPermissionRequests((previous) =>
      previous.filter((request) => !request.sessionId || request.sessionId === selectedSession?.id),
    );
  }, [selectedSession?.id]);

  const cyclePermissionMode = useCallback(() => {
    const currentIndex = PERMISSION_MODES.indexOf(permissionMode);
    const nextIndex = (currentIndex + 1) % PERMISSION_MODES.length;
    const nextMode = PERMISSION_MODES[nextIndex];
    setPermissionMode(nextMode);

    if (selectedSession?.id) {
      localStorage.setItem(`permissionMode-${selectedSession.id}`, nextMode);
    }
  }, [permissionMode, selectedSession?.id]);

  return {
    provider,
    claudeModel,
    setClaudeModel,
    permissionMode,
    setPermissionMode,
    pendingPermissionRequests,
    setPendingPermissionRequests,
    cyclePermissionMode,
  };
}
