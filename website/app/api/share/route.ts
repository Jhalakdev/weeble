import { NextResponse } from 'next/server';
import { getSessionToken } from '@/lib/session';

const API_URL = process.env.WEEBER_API_URL || 'http://localhost:3030';

// Mint a public share link for a file. Body: { file_id, file_name, mime,
// size_bytes?, expires_in_seconds?, max_downloads? }
//
// The server returns { token, url } where `token` is a cryptographically
// random 16+ byte value (unguessable). Anyone with the URL can download —
// no password — but the URL can't be brute-forced. Bytes still come from
// the user's host via the relay tunnel (no copy on the VPS).
export async function POST(req: Request) {
  const token = await getSessionToken();
  if (!token) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  const body = await req.text();
  const upstream = await fetch(`${API_URL}/v1/shares`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body,
  });
  const respBody = await upstream.text();
  return new NextResponse(respBody, {
    status: upstream.status,
    headers: { 'Content-Type': 'application/json' },
  });
}
