// authFetch — server-side wrapper around fetch() that:
//   1. reads the short-lived access token from the session cookie
//   2. adds it as a Bearer header
//   3. on 401, rotates the refresh token, updates the cookies,
//      and retries ONCE with the fresh access token
//
// All Next.js API routes that proxy to the VPS should use this
// instead of bare fetch(). Keeps refresh-on-401 logic in one place.

import { api } from '@/lib/api';
import { getRefreshToken, getSessionToken, setSession, clearSession } from '@/lib/session';

const API_URL = process.env.WEEBER_API_URL || 'http://localhost:3030';

function buildHeaders(base: HeadersInit | undefined, token: string | null): Headers {
  const h = new Headers(base ?? {});
  if (token) h.set('Authorization', `Bearer ${token}`);
  return h;
}

/// Issues `fetch($API_URL + path, init)` with a Bearer auth header.
/// On 401, transparently refreshes the token and retries. Returns the
/// ultimate Response to the caller (same shape as fetch).
export async function authFetch(path: string, init: RequestInit = {}): Promise<Response> {
  let token = await getSessionToken();
  const url = `${API_URL}${path}`;

  let res = await fetch(url, { ...init, headers: buildHeaders(init.headers, token) });
  if (res.status !== 401) return res;

  // Token expired or missing — try to refresh.
  const refresh = await getRefreshToken();
  if (!refresh) {
    // No refresh cookie. User has to log in again.
    await clearSession();
    return res;
  }
  try {
    const rotated = await api.refresh(refresh);
    // Update both cookies with the fresh pair.
    await setSession(rotated.access_token, rotated.refresh_token);
    token = rotated.access_token;
  } catch {
    // Refresh rejected (expired / revoked / reused). Clear cookies so
    // the next request triggers a clean login redirect.
    await clearSession();
    return res;
  }

  // Retry the original request exactly once with the new access token.
  return fetch(url, { ...init, headers: buildHeaders(init.headers, token) });
}
