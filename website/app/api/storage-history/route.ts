import { NextResponse } from 'next/server';
import { getSessionToken } from '@/lib/session';
import { api } from '@/lib/api';

export async function GET() {
  const token = await getSessionToken();
  if (!token) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  const res = await api.relayStorageHistory(token);
  return NextResponse.json(res ?? { history: [] });
}
