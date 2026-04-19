// Thin client for the Weeber backend API.
// All website→backend traffic goes through here.

const API_URL = process.env.WEEBER_API_URL || 'http://localhost:3030';

export type AuthResponse = {
  token: string;
  account_id: string;
  plan: string;
  status: string;
};

export type BillingStatus = {
  plan: string;
  status: string;
  renews_at: number | null;
  trial_days_remaining: number;
};

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const res = await fetch(`${API_URL}${path}`, {
    ...init,
    headers: {
      'Content-Type': 'application/json',
      ...(init.headers || {}),
    },
    cache: 'no-store',
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = new Error(body.error || `request_failed_${res.status}`);
    (err as Error & { status?: number }).status = res.status;
    throw err;
  }
  return body as T;
}

export const api = {
  register: (email: string, password: string) =>
    request<{ account_id: string }>('/v1/auth/register', {
      method: 'POST',
      body: JSON.stringify({ email, password }),
    }),

  login: (email: string, password: string) =>
    request<AuthResponse>('/v1/auth/login', {
      method: 'POST',
      body: JSON.stringify({ email, password }),
    }),

  billingStatus: (token: string) =>
    request<BillingStatus>('/v1/billing/status', {
      headers: { Authorization: `Bearer ${token}` },
    }),

  listDevices: (token: string) =>
    request<{ devices: Array<{ id: string; name: string; kind: string; platform: string; last_seen_at: number; revoked_at: number | null }> }>('/v1/devices', {
      headers: { Authorization: `Bearer ${token}` },
    }),

  listShares: (token: string) =>
    request<{ shares: Array<{ token: string; file_name: string; mime: string; size_bytes: number | null; created_at: number; expires_at: number | null; downloads: number; max_downloads: number | null; url: string }> }>('/v1/shares', {
      headers: { Authorization: `Bearer ${token}` },
    }),

  activeHost: (token: string) =>
    request<{ device_id: string; name: string; public_ip: string; port: number; cert_fingerprint: string; updated_at: number } | null>('/v1/accounts/me/active-host', {
      headers: { Authorization: `Bearer ${token}` },
    }).catch(() => null),

  relayFiles: (token: string) =>
    request<{ files: Array<{ id: string; name: string; size: number; mime: string; created_at: number; parent_id: string | null }> }>('/v1/relay/files', {
      headers: { Authorization: `Bearer ${token}` },
    }).catch(() => null),
};
