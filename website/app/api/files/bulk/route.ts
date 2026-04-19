import { NextResponse } from 'next/server';
import { getSessionToken } from '@/lib/session';

const API_URL = process.env.WEEBER_API_URL || 'http://localhost:3030';

export async function POST(req: Request) {
  const token = await getSessionToken();
  if (!token) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  const body = await req.text();
  const upstream = await fetch(`${API_URL}/v1/relay/files/bulk`, {
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
