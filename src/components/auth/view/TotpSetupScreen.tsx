import { useEffect, useState } from 'react';
import QRCode from 'qrcode';
import { authenticatedFetch } from '../../../utils/api';

type TotpSetupData = {
  secret: string;
  otpauthUri: string;
  recoveryCode: string;
};

type TotpSetupScreenProps = {
  onDone: () => void;
};

/**
 * Guides the user through TOTP setup:
 *  1. Fetches a fresh secret + QR URI from POST /api/auth/totp/setup
 *  2. Renders the QR code and manual entry key
 *  3. Displays the one-time recovery code prominently
 *  4. Accepts a 6-digit code and calls POST /api/auth/totp/verify-setup to activate
 */
export function TotpSetupScreen({ onDone }: TotpSetupScreenProps) {
  const [data, setData] = useState<TotpSetupData | null>(null);
  const [qr, setQr] = useState<string | null>(null);
  const [code, setCode] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let cancelled = false;

    (async () => {
      try {
        const res = await authenticatedFetch('/api/auth/totp/setup', { method: 'POST' });
        if (!res.ok) {
          const body = (await res.json().catch(() => ({}))) as { error?: string };
          throw new Error(body.error ?? `HTTP ${res.status}`);
        }
        const body = (await res.json()) as TotpSetupData;
        if (!cancelled) {
          setData(body);
          const dataUrl = await QRCode.toDataURL(body.otpauthUri);
          if (!cancelled) {
            setQr(dataUrl);
          }
        }
      } catch (e: unknown) {
        if (!cancelled) {
          setErr(e instanceof Error ? e.message : String(e));
        }
      }
    })();

    return () => {
      cancelled = true;
    };
  }, []);

  const submit = async () => {
    if (!data) return;
    setBusy(true);
    setErr(null);
    try {
      const r = await authenticatedFetch('/api/auth/totp/verify-setup', {
        method: 'POST',
        body: JSON.stringify({ secret: data.secret, code, recoveryCode: data.recoveryCode }),
      });
      if (!r.ok) {
        const b = (await r.json().catch(() => ({}))) as { error?: string };
        throw new Error(b.error ?? `HTTP ${r.status}`);
      }
      onDone();
    } catch (e: unknown) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  if (err) return <p className="text-red-500 text-sm">{err}</p>;
  if (!data || !qr) {
    return <p className="text-muted-foreground text-sm">Loading…</p>;
  }

  return (
    <div className="space-y-4 max-w-md mx-auto py-8">
      <h1 className="text-xl font-semibold">Set up two-factor authentication</h1>
      <p className="text-sm text-muted-foreground">
        Scan this QR code with Google Authenticator, 1Password, Authy, or any TOTP-compatible
        app, then enter the 6-digit code below.
      </p>

      <img src={qr} alt="TOTP QR code" className="w-48 h-48 mx-auto bg-white p-2 rounded" />

      <p className="text-xs text-muted-foreground break-all text-center">
        Or enter manually: <code className="font-mono">{data.secret}</code>
      </p>

      <div className="rounded border border-amber-700 bg-amber-950/40 p-3 text-sm">
        <p className="font-semibold text-amber-300">Save this recovery code now</p>
        <p className="font-mono mt-1 break-all">{data.recoveryCode}</p>
        <p className="text-xs text-amber-200/70 mt-2">
          Used once if you lose your authenticator. We will not show it again.
        </p>
      </div>

      <input
        value={code}
        onChange={(e) => setCode(e.target.value.replace(/\D/g, '').slice(0, 6))}
        inputMode="numeric"
        className="w-full rounded border border-input bg-background px-2 py-1 font-mono text-center text-2xl tracking-widest"
        placeholder="000000"
        disabled={busy}
      />

      {err && <p className="text-sm text-red-500">{err}</p>}

      <button
        onClick={submit}
        disabled={code.length !== 6 || busy}
        className="w-full rounded bg-blue-600 px-3 py-2 text-white disabled:opacity-40"
      >
        {busy ? 'Activating…' : 'Confirm and enable'}
      </button>
    </div>
  );
}
