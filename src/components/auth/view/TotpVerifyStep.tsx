import { useState } from 'react';

type TotpVerifyStepProps = {
  totpToken: string;
  onSuccess: (finalJwt: string, newRecoveryCode?: string) => void;
};

/**
 * Second-factor verification step shown after a successful password check when
 * the account has TOTP enabled. Accepts either a 6-digit TOTP code or a
 * one-shot recovery code.
 */
export function TotpVerifyStep({ totpToken, onSuccess }: TotpVerifyStepProps) {
  const [code, setCode] = useState('');
  const [recovery, setRecovery] = useState('');
  const [useRecovery, setUseRecovery] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async () => {
    setBusy(true);
    setError(null);
    try {
      const res = await fetch('/api/auth/login/totp', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          totpToken,
          ...(useRecovery ? { recoveryCode: recovery } : { code }),
        }),
      });
      const body = (await res.json()) as { token?: string; newRecoveryCode?: string; error?: string };
      if (!res.ok) throw new Error(body.error ?? `HTTP ${res.status}`);
      if (!body.token) throw new Error('No token returned from server');
      onSuccess(body.token, body.newRecoveryCode);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const isSubmitDisabled = busy || (useRecovery ? recovery.length === 0 : code.length !== 6);

  return (
    <div className="space-y-3">
      <h2 className="text-lg font-semibold">Second factor</h2>
      <p className="text-sm text-muted-foreground">
        {useRecovery
          ? 'Enter your recovery code.'
          : 'Enter the 6-digit code from your authenticator app.'}
      </p>

      {useRecovery ? (
        <input
          autoFocus
          value={recovery}
          onChange={(e) => setRecovery(e.target.value)}
          className="w-full rounded border border-input bg-background px-2 py-1 font-mono"
          placeholder="Recovery code"
          disabled={busy}
        />
      ) : (
        <input
          autoFocus
          inputMode="numeric"
          pattern="\d{6}"
          value={code}
          onChange={(e) => setCode(e.target.value.replace(/\D/g, '').slice(0, 6))}
          className="w-full rounded border border-input bg-background px-2 py-1 font-mono text-center text-2xl tracking-widest"
          placeholder="000000"
          disabled={busy}
        />
      )}

      {error && <p className="text-sm text-red-500">{error}</p>}

      <button
        onClick={submit}
        disabled={isSubmitDisabled}
        className="w-full rounded bg-blue-600 px-3 py-2 text-white disabled:opacity-40"
      >
        {busy ? 'Verifying…' : 'Verify'}
      </button>

      <button
        type="button"
        onClick={() => {
          setUseRecovery((v) => !v);
          setError(null);
          setCode('');
          setRecovery('');
        }}
        className="w-full text-xs text-muted-foreground underline"
      >
        {useRecovery ? 'Use TOTP code instead' : 'Use recovery code instead'}
      </button>
    </div>
  );
}
