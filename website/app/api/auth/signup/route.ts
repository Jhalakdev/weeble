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
    await api.register(body.email, body.password);
    const auth = await api.login(body.email, body.password);
    await setSessionToken(auth.token);
    return NextResponse.json({ ok: true });
  } catch (e) {
    const status = (e as Error & { status?: number }).status ?? 500;
    return NextResponse.json({ error: (e as Error).message }, { status });
  }
}
