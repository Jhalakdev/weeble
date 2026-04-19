import { NextResponse } from 'next/server';
import { setSession } from '@/lib/session';

const API_URL = process.env.WEEBER_API_URL || 'http://localhost:3030';

// Redeems a single-use pairing token scanned from the host's QR.
// Server verifies + consumes the token, returns a fresh access +
// refresh pair. We set both as httpOnly cookies so the browser
// continues as if the user had entered email/password.
export async function POST(req: Request) {
  const { token } = await req.json().catch(() => ({}));
  if (!token) return NextResponse.json({ error: 'missing_token' }, { status: 400 });
  const upstream = await fetch(`${API_URL}/v1/auth/pairing/redeem`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ token }),
  });
  const body = await upstream.json();
  if (!upstream.ok) {
    return NextResponse.json(body, { status: upstream.status });
  }
  // pairing/redeem returns { token, account_id, plan } — the `token`
  // there is still the ACCESS token (legacy naming). Refresh tokens
  // aren't issued by the pairing flow today; the browser will mint
  // one on its first refresh cycle by falling back to login. This
  // still lets the scan land a real session — which is the whole
  // point.
  await setSession(body.access_token ?? body.token, body.refresh_token ?? null);
  return NextResponse.json({ ok: true, account_id: body.account_id });
}
