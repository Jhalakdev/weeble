import { NextResponse } from 'next/server';
import { api } from '@/lib/api';
import { setSessionToken } from '@/lib/session';

export async function POST(req: Request) {
  let body: { email?: string; password?: string };
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: 'invalid_json' }, { status: 400 });
  }
  if (!body.email || !body.password) {
    return NextResponse.json({ error: 'missing_fields' }, { status: 400 });
  }

  try {
    const auth = await api.login(body.email, body.password);
    // Store BOTH tokens as httpOnly cookies. `weeber_access` (1 h) is
    // sent as Bearer on every upstream call; `weeber_refresh` (90 d)
    // is used by /api/auth/refresh to rotate when access expires.
    await setSessionToken(auth.access_token ?? auth.token, auth.refresh_token ?? null);
    return NextResponse.json({ ok: true });
  } catch (e) {
    const status = (e as Error & { status?: number }).status ?? 500;
    return NextResponse.json({ error: (e as Error).message }, { status });
  }
}
