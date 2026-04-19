'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';
import { Cloud } from 'lucide-react';

type Stats = { used_bytes: number; allocated_bytes: number; file_count: number };

/// Single source of truth for storage display across the website.
/// Polls /api/files (which already returns host-side stats) and renders
/// real used/allocated values from the host — never hardcoded.
///
/// Two variants:
///   - 'sidebar' — compact card for the desktop sidebar
///   - 'block' — full-width block for the account page / mobile inline
export function LiveStorageCard({ variant = 'sidebar' }: { variant?: 'sidebar' | 'block' }) {
  const [stats, setStats] = useState<Stats | null>(null);
  const [online, setOnline] = useState<boolean | null>(null);

  useEffect(() => {
    let alive = true;
    async function load() {
      try {
        const r = await fetch('/api/files', { cache: 'no-store' });
        if (!r.ok) return;
        const body = await r.json();
        if (!alive) return;
        setStats(body.stats ?? null);
        setOnline(body.host_online ?? false);
      } catch { /* offline / network — leave null */ }
    }
    load();
    const id = setInterval(load, 6000);
    return () => { alive = false; clearInterval(id); };
  }, []);

  const used = stats?.used_bytes ?? 0;
  const cap = stats?.allocated_bytes ?? 0;
  const hasCap = cap > 0;
  const pct = hasCap ? Math.min(100, (used / cap) * 100) : 0;
  const free = Math.max(0, cap - used);

  const usedTxt = formatBytes(used);
  const capTxt = hasCap ? formatBytes(cap) : '—';

  if (variant === 'sidebar') {
    return (
      <div className="bg-[color:var(--body)] rounded-xl p-3.5">
        <div className="flex items-center gap-1.5 mb-2.5">
          <Cloud size={14} className="text-[color:var(--accent)]" />
          <span className="text-[13px] font-semibold">Storage</span>
        </div>
        <div className="text-[11px] text-[color:var(--text-muted)] mb-1.5">
          {online === false ? 'Host offline' : `${usedTxt} / ${capTxt} used`}
        </div>
        <div className="h-1 rounded-full bg-[color:var(--border)] overflow-hidden mb-1.5">
          <div className="h-full rounded-full bg-[color:var(--accent)]" style={{ width: `${pct}%`, transition: 'width 300ms ease' }} />
        </div>
        <div className="text-[10px] text-[color:var(--text-muted)] mb-3">
          {hasCap ? `${pct.toFixed(0)}% Full · ${formatBytes(free)} Free` : 'Open the Weeber app on your computer to set up storage.'}
        </div>
        <Link
          href="/dashboard/account"
          className="block text-center bg-[color:var(--accent)] hover:bg-[color:var(--accent-hover)] text-white text-[11px] font-medium py-2 rounded-md"
          title="Storage lives on your computer. To make room, open the Weeber app on your computer and increase the allocation."
        >
          Increase storage
        </Link>
      </div>
    );
  }

  // 'block'
  return (
    <div className="rounded-2xl border border-[color:var(--border)] bg-[color:var(--surface)] p-5">
      <div className="flex items-center gap-2 mb-3">
        <div className="w-9 h-9 rounded-xl bg-[color:var(--accent-muted)] text-[color:var(--accent)] flex items-center justify-center">
          <Cloud size={18} />
        </div>
        <div>
          <div className="text-[14px] font-semibold">Storage</div>
          <div className="text-[11px] text-[color:var(--text-muted)]">
            {online === false ? 'Host offline — open the Weeber app on your computer.' : 'Lives on your computer'}
          </div>
        </div>
      </div>
      <div className="text-[13px] mb-2">
        <span className="font-semibold">{usedTxt}</span>
        <span className="text-[color:var(--text-muted)]"> of {capTxt} used</span>
      </div>
      <div className="h-1.5 rounded-full bg-[color:var(--border)] overflow-hidden mb-2">
        <div className="h-full rounded-full" style={{ width: `${pct}%`, background: 'linear-gradient(90deg, #8F93F6 0%, #6E74F2 100%)', transition: 'width 300ms ease' }} />
      </div>
      <div className="text-[11px] text-[color:var(--text-muted)] mb-3">
        {hasCap ? `${pct.toFixed(0)}% full · ${formatBytes(free)} free · ${stats?.file_count ?? 0} files` : 'Allocation not set yet.'}
      </div>
      <p className="text-[11px] text-[color:var(--text-muted)] leading-relaxed">
        Storage is on your own computer — Weeber doesn&rsquo;t sell storage. To make room for more files, open the Weeber app on your computer →
        <span className="text-[color:var(--text)] font-medium"> Increase storage</span> in the sidebar.
      </p>
    </div>
  );
}

function formatBytes(b: number) {
  if (b < 1024) return `${b} B`;
  const u = ['KB', 'MB', 'GB', 'TB'];
  let v = b / 1024, i = 0;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(v >= 100 ? 0 : 1)} ${u[i]}`;
}
