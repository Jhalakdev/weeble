import { NextResponse } from 'next/server';
import { getSessionToken } from '@/lib/session';

const API_URL = process.env.WEEBER_API_URL || 'http://localhost:3030';

// POST → mint a one-time pairing token the phone can scan + redeem
// from the install (so they don't have to type their email/password
// again on the small screen).
export async function POST() {
  const token = await getSessionToken();
  if (!token) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  const upstream = await fetch(`${API_URL}/v1/auth/pairing/create`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: '{}',
  });
  const body = await upstream.text();
  return new NextResponse(body, {
    status: upstream.status,
    headers: { 'Content-Type': 'application/json' },
  });
}
