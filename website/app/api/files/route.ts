import { NextResponse } from 'next/server';
import { getSessionToken } from '@/lib/session';
import { api } from '@/lib/api';

const API_URL = process.env.WEEBER_API_URL || 'http://localhost:3030';

export async function GET(req: Request) {
  const token = await getSessionToken();
  if (!token) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });

  const url = new URL(req.url);
  const parent = url.searchParams.get('parent') ?? '';
  const includeDeleted = url.searchParams.get('include_deleted') === 'true';

  const activeHost = await api.activeHost(token);
  if (!activeHost) {
    return NextResponse.json({
      files: [], path: [],
      host_online: false, host_name: null,
      reachable: false, reason: 'no_active_host',
    });
  }

  const [res, stats] = await Promise.all([
    api.relayFiles(token, { parent, includeDeleted }),
    api.relayStats(token),
  ]);
  if (!res) {
    return NextResponse.json({
      files: [], path: [],
      host_online: true, host_name: activeHost.name ?? null,
      reachable: false, reason: 'relay_unreachable',
    });
  }
  return NextResponse.json({
    files: res.files,
    path: res.path ?? [],
    host_online: true,
    host_name: activeHost.name ?? null,
    reachable: true,
    stats: stats ?? null,
  });
}

export async function POST(req: Request) {
  const token = await getSessionToken();
  if (!token) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });

  const url = new URL(req.url);
  const name = url.searchParams.get('name');
  const mime = url.searchParams.get('mime') ?? 'application/octet-stream';
  const parent = url.searchParams.get('parent') ?? '';
  if (!name) return NextResponse.json({ error: 'missing_name' }, { status: 400 });

  const upstream = await fetch(
    `${API_URL}/v1/relay/upload?name=${encodeURIComponent(name)}&mime=${encodeURIComponent(mime)}${parent ? `&parent=${encodeURIComponent(parent)}` : ''}`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/octet-stream',
        'Content-Length': req.headers.get('content-length') ?? '0',
      },
      body: req.body,
      // @ts-expect-error — Node fetch accepts streaming bodies with duplex.
      duplex: 'half',
    },
  );
  const body = await upstream.text();
  return new NextResponse(body, { status: upstream.status, headers: { 'Content-Type': 'application/json' } });
}
