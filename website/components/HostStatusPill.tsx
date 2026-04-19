'use client';

import { useEffect, useState } from 'react';

type HostStatus = 'loading' | 'online' | 'offline' | 'error';

export function HostStatusPill({ compact = false }: { compact?: boolean }) {
  const [status, setStatus] = useState<HostStatus>('loading');
  const [hostName, setHostName] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    async function check() {
      try {
        const r = await fetch('/api/files', { cache: 'no-store' });
        if (cancelled) return;
        if (!r.ok) { setStatus('error'); return; }
        const body = await r.json();
        setStatus(body.host_online ? 'online' : 'offline');
        if (body.host_name) setHostName(body.host_name);
      } catch { if (!cancelled) setStatus('error'); }
    }
    check();
    const interval = setInterval(check, 15000);
    const onVis = () => { if (document.visibilityState === 'visible') check(); };
    document.addEventListener('visibilitychange', onVis);
    return () => {
      cancelled = true; clearInterval(interval);
      document.removeEventListener('visibilitychange', onVis);
    };
  }, []);

  const { color, bg, label } = decode(status, hostName);

  return (
    <div
      className={`inline-flex items-center gap-2 rounded-full font-medium transition-colors ${
        compact ? 'px-2 py-1 text-[10px]' : 'px-3 py-1.5 text-[11px]'
      }`}
      style={{ background: bg, color }}
    >
      <span className="relative flex h-2 w-2">
        {status === 'online' && (
          <span
            className="animate-pulse-ring absolute inline-flex h-full w-full rounded-full"
            style={{ background: color }}
          />
        )}
        <span className="relative inline-flex rounded-full h-2 w-2" style={{ background: color }} />
      </span>
      <span className="whitespace-nowrap">{label}</span>
    </div>
  );
}

function decode(s: HostStatus, hostName: string | null) {
  switch (s) {
    case 'loading': return { color: '#64748B', bg: '#F1F5F9', label: 'Checking…' };
    case 'online':  return { color: '#059669', bg: '#D1FAE5', label: hostName ? `Online · ${hostName}` : 'Online' };
    case 'offline': return { color: '#B45309', bg: '#FEF3C7', label: 'Storage offline' };
    case 'error':   return { color: '#B91C1C', bg: '#FEE2E2', label: 'Connection error' };
  }
}
