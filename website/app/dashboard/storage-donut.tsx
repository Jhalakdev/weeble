'use client';

import { useEffect, useState } from 'react';
import { Cloud, Sparkles } from 'lucide-react';
import Link from 'next/link';

type Stats = { used_bytes: number; allocated_bytes: number; file_count: number };

/// SVG donut chart showing host storage utilization. Polls /api/files
/// every 8s so it stays live while the user is on the dashboard.
export function StorageDonut({
  usedBytes: initialUsed, allocatedBytes: initialCap, fileCount: initialCount, plan,
}: {
  usedBytes: number;
  allocatedBytes: number;
  fileCount: number;
  plan: string;
}) {
  const [stats, setStats] = useState<Stats>({
    used_bytes: initialUsed, allocated_bytes: initialCap, file_count: initialCount,
  });

  useEffect(() => {
    let alive = true;
    async function tick() {
      try {
        const r = await fetch('/api/files', { cache: 'no-store' });
        if (!r.ok) return;
        const body = await r.json();
        if (alive && body.stats) setStats(body.stats);
      } catch { /* offline — keep last */ }
    }
    const id = setInterval(tick, 8000);
    return () => { alive = false; clearInterval(id); };
  }, []);

  const used = stats.used_bytes;
  const cap = stats.allocated_bytes;
  const free = Math.max(0, cap - used);
  const hasCap = cap > 0;
  const pct = hasCap ? Math.min(100, (used / cap) * 100) : 0;

  // SVG geometry for the donut.
  const size = 200;
  const strokeWidth = 22;
  const radius = (size - strokeWidth) / 2;
  const c = 2 * Math.PI * radius;
  const offset = c * (1 - pct / 100);

  return (
    <div className="rounded-2xl bg-[color:var(--surface)] border border-[color:var(--border)] p-5 shadow-sm h-full">
      <div className="flex items-center justify-between mb-4">
        <div>
          <h3 className="text-[15px] font-semibold tracking-tight">Storage</h3>
          <p className="text-[11px] text-[color:var(--text-muted)] mt-0.5">Lives on your computer</p>
        </div>
        <div className="inline-flex items-center gap-1 text-[10px] uppercase tracking-[0.08em] font-semibold bg-[color:var(--accent-muted)] text-[color:var(--accent)] px-2.5 py-1 rounded-full">
          <Sparkles size={10} /> {plan === 'trial' ? 'Trial' : plan}
        </div>
      </div>

      <div className="flex flex-col sm:flex-row items-center gap-6 py-2">
        {/* Donut */}
        <div className="relative flex-shrink-0" style={{ width: size, height: size }}>
          <svg width={size} height={size} className="-rotate-90">
            <defs>
              <linearGradient id="donut-grad" x1="0%" y1="0%" x2="100%" y2="100%">
                <stop offset="0%" stopColor="#8F93F6" />
                <stop offset="100%" stopColor="#6E74F2" />
              </linearGradient>
            </defs>
            <circle
              cx={size / 2}
              cy={size / 2}
              r={radius}
              fill="none"
              stroke="var(--border)"
              strokeWidth={strokeWidth}
            />
            <circle
              cx={size / 2}
              cy={size / 2}
              r={radius}
              fill="none"
              stroke="url(#donut-grad)"
              strokeWidth={strokeWidth}
              strokeLinecap="round"
              strokeDasharray={c}
              strokeDashoffset={offset}
              style={{ transition: 'stroke-dashoffset 600ms ease-out' }}
            />
          </svg>
          <div className="absolute inset-0 flex flex-col items-center justify-center text-center">
            <div className="text-[28px] font-bold tracking-tight leading-none">{hasCap ? `${pct.toFixed(0)}%` : '—'}</div>
            <div className="text-[10px] text-[color:var(--text-muted)] mt-1.5 uppercase tracking-[0.06em] font-semibold">used</div>
          </div>
        </div>

        {/* Legend */}
        <div className="flex-1 w-full space-y-3">
          <Row dotColor="linear-gradient(135deg, #8F93F6 0%, #6E74F2 100%)" label="Used" value={formatBytes(used)} muted={`${stats.file_count} file${stats.file_count === 1 ? '' : 's'}`} />
          <Row dotColor="var(--border)" label="Free" value={hasCap ? formatBytes(free) : '—'} muted={hasCap ? '' : 'Set a cap on your computer'} />
          <Row dotColor="transparent" label="Total" value={hasCap ? formatBytes(cap) : '—'} muted="" boldValue />

          <Link
            href="/dashboard/files"
            className="mt-4 inline-flex items-center gap-1.5 text-[11.5px] font-semibold text-[color:var(--accent)] hover:underline"
          >
            <Cloud size={12} /> Manage files
          </Link>
        </div>
      </div>
    </div>
  );
}

function Row({ dotColor, label, value, muted, boldValue }: { dotColor: string; label: string; value: string; muted: string; boldValue?: boolean }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <div className="flex items-center gap-2.5 min-w-0">
        <span className="w-2.5 h-2.5 rounded-full flex-shrink-0" style={{ background: dotColor }} />
        <span className="text-[12px] font-medium text-[color:var(--text)] uppercase tracking-[0.05em]">{label}</span>
      </div>
      <div className="text-right min-w-0">
        <div className={`text-[13.5px] ${boldValue ? 'font-bold' : 'font-semibold'} text-[color:var(--text)]`}>{value}</div>
        {muted && <div className="text-[10px] text-[color:var(--text-muted)]">{muted}</div>}
      </div>
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
