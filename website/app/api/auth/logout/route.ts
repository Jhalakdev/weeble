import { NextResponse } from 'next/server';
import { api } from '@/lib/api';
import { clearSession, getRefreshToken } from '@/lib/session';

export async function POST() {
  // Revoke the refresh token server-side so it can't be rotated again
  // even if it leaks. Failure here (e.g. network flake) is non-fatal —
  // we still clear the cookies locally so the user is out.
  const refresh = await getRefreshToken();
  if (refresh) await api.logout(refresh);
  await clearSession();
  return NextResponse.json({ ok: true });
}
