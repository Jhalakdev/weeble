// Server-side session management. JWT lives in an httpOnly cookie.
// We deliberately avoid storing user info in the cookie — only the bearer token.

import { cookies } from 'next/headers';

const COOKIE = 'weeber_token';

export async function setSessionToken(token: string) {
  const c = await cookies();
  // `secure: true` requires HTTPS. Enable it only when served via HTTPS
  // (inferred from the NEXT_PUBLIC_SITE_URL). Until we put TLS in front of
  // the website, we leave it false so the cookie is accepted on HTTP.
  const siteUrl = process.env.NEXT_PUBLIC_SITE_URL || '';
  const overHttps = siteUrl.startsWith('https://');
  c.set(COOKIE, token, {
    httpOnly: true,
    secure: overHttps,
    sameSite: 'lax',
    path: '/',
    maxAge: 60 * 60,
  });
}

export async function getSessionToken(): Promise<string | null> {
  const c = await cookies();
  return c.get(COOKIE)?.value ?? null;
}

export async function clearSession() {
  const c = await cookies();
  c.delete(COOKIE);
}
