const DEVICE_ID_KEY = 'im:device-id';

/** Stable per-browser device id (random uuid), persisted in localStorage. */
export function getDeviceId(): string {
  try {
    let id = localStorage.getItem(DEVICE_ID_KEY);
    if (!id) {
      id = crypto.randomUUID();
      localStorage.setItem(DEVICE_ID_KEY, id);
    }
    return id;
  } catch {
    // localStorage disabled — fall back to an ephemeral id for this page load.
    return crypto.randomUUID();
  }
}
