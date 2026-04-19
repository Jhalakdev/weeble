'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { QrCode } from 'lucide-react';
import { QRScanner } from '@/components/QRScanner';

export default function LoginPage() {
  const router = useRouter();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [scanning, setScanning] = useState(false);

  // QR sign-in: scan the QR from the Weeber app's "Pair with QR"
  // screen on the user's Mac. Token is single-use + expires in 60 s.
  async function onScan(token: string) {
    setScanning(false);
    setError(null);
    setLoading(true);
    try {
      const res = await fetch('/api/auth/pair', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ token }),
      });
      if (!res.ok) {
        const body = await res.json().catch(() => ({}));
        setError(body.error === 'invalid_or_expired' ? 'QR expired. Ask your computer for a new one.' : 'Pairing failed.');
        return;
      }
      router.push('/dashboard');
    } catch {
      setError('Network error while pairing.');
    } finally {
      setLoading(false);
    }
  }

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    try {
      const res = await fetch('/api/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password }),
      });
      const body = await res.json();
      if (!res.ok) {
        setError(body.error === 'invalid_credentials' ? 'Invalid email or password.' : 'Login failed.');
        return;
      }
      router.push('/dashboard');
    } catch {
      setError('Network error. Try again.');
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="mx-auto max-w-md px-6 py-16">
      <h1 className="text-3xl font-semibold">Log in</h1>

      <form onSubmit={onSubmit} className="mt-8 space-y-4">
        <label className="block">
          <span className="text-sm font-medium">Email</span>
          <input
            type="email"
            required
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className="mt-1 block w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-slate-900 focus:outline-none"
          />
        </label>
        <label className="block">
          <span className="text-sm font-medium">Password</span>
          <input
            type="password"
            required
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className="mt-1 block w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-slate-900 focus:outline-none"
          />
        </label>
        {error && (
          <div className="rounded-md bg-red-50 border border-red-200 px-3 py-2 text-sm text-red-700">
            {error}
          </div>
        )}
        <button
          type="submit"
          disabled={loading}
          className="w-full rounded-md bg-slate-900 px-4 py-2.5 text-white font-medium hover:bg-slate-700 disabled:opacity-60"
        >
          {loading ? 'Logging in…' : 'Log in'}
        </button>
      </form>

      {/* Divider + QR sign-in. The Mac / Windows / Linux Weeber app
          has a "Pair with QR" screen that shows a scannable code. Point
          this phone's camera at that screen and the session hops over. */}
      <div className="flex items-center gap-3 my-6 text-[11px] text-slate-400 uppercase tracking-wider">
        <div className="flex-1 h-px bg-slate-200" />
        or
        <div className="flex-1 h-px bg-slate-200" />
      </div>

      <button
        type="button"
        onClick={() => setScanning(true)}
        disabled={loading}
        className="w-full inline-flex items-center justify-center gap-2 rounded-md border border-slate-300 px-4 py-2.5 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-60"
      >
        <QrCode size={16} /> Scan QR shown on your computer
      </button>

      <p className="mt-6 text-sm text-slate-600 text-center">
        Don&apos;t have an account?{' '}
        <Link href="/signup" className="underline">
          Sign up
        </Link>
      </p>

      {scanning && (
        <QRScanner onScan={onScan} onClose={() => setScanning(false)} />
      )}
    </div>
  );
}
