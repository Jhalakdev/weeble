// Server-side session management. Dual httpOnly cookies:
//   weeber_access  — short-lived JWT (1 h), used as the Bearer in
//                    every upstream API call.
//   weeber_refresh — long-lived rotating refresh token (90 d), used
//                    ONLY by /api/auth/refresh to mint a new pair.
//
// Both cookies are httpOnly so JS on the page can never read them.
// Refresh is done entirely on the server side via the /api/auth/*
// routes, which proxy to the VPS and re-set the cookies.

import { cookies } from 'next/headers';

const ACCESS_COOKIE = 'weeber_access';
const REFRESH_COOKIE = 'weeber_refresh';
// Legacy cookie name from the old single-token era — we still accept it
// on reads so existing sessions keep working through the transition.
const LEGACY_COOKIE = 'weeber_token';

const ACCESS_MAX_AGE = 60 * 60;             // 1 hour
const REFRESH_MAX_AGE = 90 * 24 * 60 * 60;  // 90 days

function baseCookieOpts() {
  const siteUrl = process.env.NEXT_PUBLIC_SITE_URL || '';
  const overHttps = siteUrl.startsWith('https://');
  return {
    httpOnly: true,
    secure: overHttps,
    sameSite: 'lax' as const,
    path: '/',
  };
}

export async function setSession(access: string, refresh: string | null) {
  const c = await cookies();
  c.set(ACCESS_COOKIE, access, { ...baseCookieOpts(), maxAge: ACCESS_MAX_AGE });
  if (refresh) {
    c.set(REFRESH_COOKIE, refresh, { ...baseCookieOpts(), maxAge: REFRESH_MAX_AGE });
  }
  // Clear the legacy cookie once we've migrated to the new pair.
  c.delete(LEGACY_COOKIE);
}

// Back-compat alias used by the auth/login route.
export async function setSessionToken(token: string, refreshToken?: string | null) {
  await setSession(token, refreshToken ?? null);
}

export async function getSessionToken(): Promise<string | null> {
  const c = await cookies();
  const raw = c.get(ACCESS_COOKIE)?.value ?? c.get(LEGACY_COOKIE)?.value ?? null;
  if (!raw) return null;
  // Proactive refresh: if the access token is within 60 s of expiry
  // (or already past), rotate now so the next upstream call uses a
  // fresh one and can't 401 mid-request. Also kicks in when the
  // legacy single-token cookie is still set.
  if (_nearExpiry(raw)) {
    const refresh = c.get(REFRESH_COOKIE)?.value;
    if (refresh) {
      try {
        const { api } = await import('./api');
        const rotated = await api.refresh(refresh);
        await setSession(rotated.access_token, rotated.refresh_token);
        return rotated.access_token;
      } catch {
        // Refresh failed — fall through with the (stale) access token.
        // authFetch will catch the resulting 401 and clear the session.
      }
    }
  }
  return raw;
}

function _nearExpiry(jwt: string): boolean {
  try {
    const [, payload] = jwt.split('.');
    if (!payload) return false;
    const padded = payload.padEnd(payload.length + ((4 - (payload.length % 4)) % 4), '=');
    const decoded = JSON.parse(Buffer.from(padded.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString());
    if (typeof decoded.exp !== 'number') return false;
    const secondsLeft = decoded.exp - Math.floor(Date.now() / 1000);
    return secondsLeft < 60;
  } catch {
    return false;
  }
}

export async function getRefreshToken(): Promise<string | null> {
  const c = await cookies();
  return c.get(REFRESH_COOKIE)?.value ?? null;
}

export async function clearSession() {
  const c = await cookies();
  c.delete(ACCESS_COOKIE);
  c.delete(REFRESH_COOKIE);
  c.delete(LEGACY_COOKIE);
}
