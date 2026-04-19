import Link from 'next/link';
import { getSessionToken } from '@/lib/session';

export async function MarketingHeader() {
  const token = await getSessionToken();
  const loggedIn = !!token;
  return (
    <header className="border-b border-[color:var(--border)] bg-[color:var(--surface)]">
      <nav className="mx-auto flex max-w-6xl items-center justify-between px-6 py-4">
        <Link href="/" className="flex items-center gap-2 text-xl font-semibold tracking-tight">
          <span className="inline-flex h-7 w-7 items-center justify-center rounded-lg bg-gradient-to-br from-[#8f93f6] to-[#afb3fa]">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="white" xmlns="http://www.w3.org/2000/svg">
              <path d="M19.35 10.04A7.49 7.49 0 0 0 12 4C9.11 4 6.6 5.64 5.35 8.04A5.994 5.994 0 0 0 0 14a6 6 0 0 0 6 6h13a5 5 0 0 0 5-5c0-2.64-2.05-4.78-4.65-4.96z" />
            </svg>
          </span>
          <span><span className="font-light">Wee</span><span className="font-bold">BER</span></span>
        </Link>
        <div className="flex items-center gap-6 text-sm">
          <Link href="/pricing" className="text-[color:var(--text-muted)] hover:text-[color:var(--text-primary)]">Pricing</Link>
          <Link href="/download" className="text-[color:var(--text-muted)] hover:text-[color:var(--text-primary)]">Download</Link>
          {loggedIn ? (
            <Link href="/dashboard" className="rounded-lg bg-[color:var(--accent)] px-3 py-1.5 text-white hover:bg-[color:var(--accent-hover)]">
              ← Back to dashboard
            </Link>
          ) : (
            <>
              <Link href="/login" className="rounded-lg border border-[color:var(--border)] px-3 py-1.5 hover:bg-[color:var(--accent-muted)]">Log in</Link>
              <Link href="/signup" className="rounded-lg bg-[color:var(--accent)] px-3 py-1.5 text-white hover:bg-[color:var(--accent-hover)]">Sign up</Link>
            </>
          )}
        </div>
      </nav>
    </header>
  );
}

export function MarketingFooter() {
  return (
    <footer className="border-t border-[color:var(--border)] mt-16 bg-[color:var(--surface)]">
      <div className="mx-auto max-w-6xl px-6 py-8 text-sm text-[color:var(--text-muted)] flex justify-between">
        <span>© {new Date().getFullYear()} Weeber</span>
        <div className="flex gap-4">
          <Link href="/privacy">Privacy</Link>
          <Link href="/terms">Terms</Link>
        </div>
      </div>
    </footer>
  );
}
