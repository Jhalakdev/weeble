import { NextResponse } from 'next/server';
import { getSessionToken } from '@/lib/session';
import { api } from '@/lib/api';

const API_URL = process.env.WEEBER_API_URL || 'http://localhost:3030';

export async function GET() {
  const token = await getSessionToken();
  if (!token) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });

  // The "online" signal comes from active-host: if the VPS has a recent
  // host endpoint registered, the Mac is alive and heartbeating.
  // The relay file list is a SEPARATE concern — it can fail (host
  // unreachable from internet due to no port forwarding / no UPnP) even
  // when active-host succeeds.
  const activeHost = await api.activeHost(token);
  if (!activeHost) {
    return NextResponse.json({
      files: [],
      host_online: false,
      host_name: null,
      reachable: false,
      reason: 'no_active_host',
    });
  }

  // Try the relay; if it times out, surface that distinctly so the UI
  // can show a meaningful "online but unreachable" state.
  const [res, stats] = await Promise.all([
    api.relayFiles(token),
    api.relayStats(token),
  ]);
  if (!res) {
    return NextResponse.json({
      files: [],
      host_online: true,
      host_name: activeHost.name ?? null,
      reachable: false,
      reason: 'relay_unreachable',
    });
  }
  return NextResponse.json({
    files: res.files,
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
  if (!name) return NextResponse.json({ error: 'missing_name' }, { status: 400 });

  const upstream = await fetch(
    `${API_URL}/v1/relay/upload?name=${encodeURIComponent(name)}&mime=${encodeURIComponent(mime)}`,
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
