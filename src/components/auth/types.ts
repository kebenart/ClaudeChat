import type { ReactNode } from 'react';

export type AuthUser = {
  id?: number | string;
  username: string;
  totpEnabled?: boolean;
  [key: string]: unknown;
};

export type AuthActionResult = { success: true } | { success: false; error: string };

export type AuthSessionPayload = {
  token?: string;
  user?: AuthUser;
  error?: string;
  message?: string;
  /** Present when the login response requires a second factor. */
  requiresTotp?: boolean;
  /** Short-lived JWT exchanged for the real session token after TOTP verification. */
  totpToken?: string;
};

export type TotpVerifyPayload = {
  token?: string;
  /** Returned when a recovery code was consumed — the user must save the new one. */
  newRecoveryCode?: string;
  error?: string;
};

export type AuthStatusPayload = {
  needsSetup?: boolean;
  /** Server is in DEV_AUTH_BYPASS=1 mode — all auth disabled, skip login UI. */
  devBypass?: boolean;
};

export type AuthUserPayload = {
  user?: AuthUser;
};

export type OnboardingStatusPayload = {
  hasCompletedOnboarding?: boolean;
};

export type ApiErrorPayload = {
  error?: string;
  message?: string;
};

export type AuthContextValue = {
  user: AuthUser | null;
  token: string | null;
  isLoading: boolean;
  needsSetup: boolean;
  hasCompletedOnboarding: boolean;
  error: string | null;
  login: (username: string, password: string) => Promise<AuthActionResult>;
  register: (username: string, password: string) => Promise<AuthActionResult>;
  logout: () => void;
  refreshOnboardingStatus: () => Promise<void>;
  /**
   * Finalise a login that completed outside the normal `login()` flow
   * (e.g. after a successful TOTP second-factor exchange).
   * Stores the token, fetches the user profile, and runs onboarding check.
   */
  finalizeLogin: (jwt: string) => Promise<AuthActionResult>;
};

export type AuthProviderProps = {
  children: ReactNode;
};
