import { useCallback, useState } from 'react';
import type { FormEvent } from 'react';
import { useTranslation } from 'react-i18next';
import { useAuth } from '../context/AuthContext';
import type { AuthSessionPayload } from '../types';
import { parseJsonSafely } from '../utils';
import AuthErrorAlert from './AuthErrorAlert';
import AuthInputField from './AuthInputField';
import AuthScreenLayout from './AuthScreenLayout';
import { TotpVerifyStep } from './TotpVerifyStep';

type LoginFormState = {
  username: string;
  password: string;
};

const initialState: LoginFormState = {
  username: '',
  password: '',
};

/**
 * Login form component.
 * Handles credential input with browser autofill support (`autocomplete`
 * attributes) so that password managers can offer to fill saved credentials.
 *
 * When the server returns `requiresTotp: true` the form transitions to the
 * TOTP second-factor step rather than completing the session immediately.
 */
export default function LoginForm() {
  const { t } = useTranslation('auth');
  const { finalizeLogin } = useAuth();

  const [formState, setFormState] = useState<LoginFormState>(initialState);
  const [errorMessage, setErrorMessage] = useState('');
  const [isSubmitting, setIsSubmitting] = useState(false);

  // When set, password step is done and we are waiting for the second factor.
  const [pendingTotpToken, setPendingTotpToken] = useState<string | null>(null);
  // Banner shown once after a recovery-code login that rotates the code.
  const [newRecoveryCode, setNewRecoveryCode] = useState<string | null>(null);

  const updateField = useCallback((field: keyof LoginFormState, value: string) => {
    setFormState((previous) => ({ ...previous, [field]: value }));
  }, []);

  const handleSubmit = useCallback(
    async (event: FormEvent<HTMLFormElement>) => {
      event.preventDefault();
      setErrorMessage('');

      // Keep form validation local so each auth screen owns its own UI feedback.
      if (!formState.username.trim() || !formState.password) {
        setErrorMessage(t('login.errors.requiredFields'));
        return;
      }

      setIsSubmitting(true);
      try {
        const response = await fetch('/api/auth/login', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            username: formState.username.trim(),
            password: formState.password,
          }),
        });

        const payload = await parseJsonSafely<AuthSessionPayload>(response);

        if (!response.ok) {
          setErrorMessage(payload?.error ?? payload?.message ?? t('login.errors.invalidCredentials', 'Invalid credentials'));
          return;
        }

        // Two-factor required: transition to TOTP step (do NOT store the totpToken as a session JWT).
        if (payload?.requiresTotp && payload.totpToken) {
          setPendingTotpToken(payload.totpToken);
          return;
        }

        // Normal single-factor: token + user returned directly.
        if (payload?.token) {
          const result = await finalizeLogin(payload.token);
          if (!result.success) {
            setErrorMessage(result.error);
          }
          return;
        }

        setErrorMessage(t('login.errors.invalidCredentials', 'Login failed — no token received'));
      } finally {
        setIsSubmitting(false);
      }
    },
    [formState.password, formState.username, finalizeLogin, t],
  );

  const handleTotpSuccess = useCallback(
    async (finalJwt: string, rotatedRecoveryCode?: string) => {
      if (rotatedRecoveryCode) {
        // Surface the new recovery code before completing session setup.
        setNewRecoveryCode(rotatedRecoveryCode);
        // Store jwt temporarily so we can finalize after the banner is dismissed.
        setPendingTotpToken(finalJwt);
        return;
      }

      const result = await finalizeLogin(finalJwt);
      if (!result.success) {
        setErrorMessage(result.error);
        setPendingTotpToken(null);
      }
    },
    [finalizeLogin],
  );

  const handleRecoveryCodeDismissed = useCallback(async () => {
    if (!pendingTotpToken) return;
    const jwt = pendingTotpToken;
    setNewRecoveryCode(null);
    setPendingTotpToken(null);
    const result = await finalizeLogin(jwt);
    if (!result.success) {
      setErrorMessage(result.error);
    }
  }, [finalizeLogin, pendingTotpToken]);

  // New-recovery-code banner (shown after a successful recovery-code login).
  if (newRecoveryCode) {
    return (
      <AuthScreenLayout
        title="Save your new recovery code"
        description="Your old recovery code has been consumed. Save this one now — it will not be shown again."
        footerText=""
      >
        <div className="space-y-4">
          <div className="rounded border border-amber-700 bg-amber-950/40 p-4">
            <p className="font-semibold text-amber-300">New recovery code</p>
            <p className="mt-2 font-mono text-lg break-all">{newRecoveryCode}</p>
          </div>
          <button
            onClick={handleRecoveryCodeDismissed}
            className="w-full rounded-md bg-blue-600 px-4 py-2 font-medium text-white hover:bg-blue-700"
          >
            I have saved my recovery code
          </button>
        </div>
      </AuthScreenLayout>
    );
  }

  // TOTP second-factor step.
  if (pendingTotpToken) {
    return (
      <AuthScreenLayout
        title={t('login.title')}
        description="Two-factor authentication"
        footerText=""
      >
        <TotpVerifyStep totpToken={pendingTotpToken} onSuccess={handleTotpSuccess} />
      </AuthScreenLayout>
    );
  }

  // Password step (normal path).
  return (
    <AuthScreenLayout
      title={t('login.title')}
      description={t('login.description')}
      footerText="Enter your credentials to access CloudCLI"
    >
      <form onSubmit={handleSubmit} className="space-y-4">
        <AuthInputField
          id="username"
          label={t('login.username')}
          value={formState.username}
          onChange={(value) => updateField('username', value)}
          placeholder={t('login.placeholders.username')}
          isDisabled={isSubmitting}
          autoComplete="username"
        />

        <AuthInputField
          id="password"
          label={t('login.password')}
          value={formState.password}
          onChange={(value) => updateField('password', value)}
          placeholder={t('login.placeholders.password')}
          isDisabled={isSubmitting}
          type="password"
          autoComplete="current-password"
        />

        <AuthErrorAlert errorMessage={errorMessage} />

        <button
          type="submit"
          disabled={isSubmitting}
          className="w-full rounded-md bg-blue-600 px-4 py-2 font-medium text-white transition-colors duration-200 hover:bg-blue-700 disabled:bg-blue-400"
        >
          {isSubmitting ? t('login.loading') : t('login.submit')}
        </button>
      </form>
    </AuthScreenLayout>
  );
}
