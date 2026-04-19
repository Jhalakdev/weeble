import { NextResponse } from 'next/server';
import { getSessionToken } from '@/lib/session';

const API_URL = process.env.WEEBER_API_URL || 'http://localhost:3030';

export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const token = await getSessionToken();
  if (!token) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  const { id } = await params;
  const upstream = await fetch(`${API_URL}/v1/relay/files/${encodeURIComponent(id)}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!upstream.ok) {
    return NextResponse.json({ error: 'fetch_failed', status: upstream.status }, { status: upstream.status });
  }
  const headers = new Headers();
  const ct = upstream.headers.get('content-type');
  const cl = upstream.headers.get('content-length');
  const cd = upstream.headers.get('content-disposition');
  if (ct) headers.set('content-type', ct);
  if (cl) headers.set('content-length', cl);
  if (cd) headers.set('content-disposition', cd);
  return new NextResponse(upstream.body, { headers });
}
