import { NextResponse } from 'next/server';
import { getSessionToken } from '@/lib/session';

const API_URL = process.env.WEEBER_API_URL || 'http://localhost:3030';

export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const token = await getSessionToken();
  if (!token) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  const { id } = await params;
  const body = await req.text();
  const upstream = await fetch(`${API_URL}/v1/relay/files/${encodeURIComponent(id)}/copy`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: body || '{}',
  });
  const respBody = await upstream.text();
  return new NextResponse(respBody, {
    status: upstream.status,
    headers: { 'Content-Type': 'application/json' },
  });
}
