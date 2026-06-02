import type { ProjectSession } from '../../../types/app';

export function resolveAuthUrlForDisplay(_command: string | null | undefined, authUrl: string): string {
  return authUrl;
}

export function getSessionDisplayName(session: ProjectSession | null | undefined): string | null {
  if (!session) {
    return null;
  }

  return session.summary || 'New Session';
}
