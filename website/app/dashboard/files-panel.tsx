'use client';

import { useEffect, useRef, useState } from 'react';
import { Upload, Download, FileText, CloudOff, RefreshCw, File } from 'lucide-react';

type FileItem = { id: string; name: string; size: number; mime: string; created_at: number };

export function FilesPanel({ initialFiles, hostOnline }: { initialFiles: FileItem[]; hostOnline: boolean }) {
  const [files, setFiles] = useState<FileItem[]>(initialFiles);
  const [online, setOnline] = useState(hostOnline);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pullDist, setPullDist] = useState(0);   // visual pull-to-refresh offset
  const inputRef = useRef<HTMLInputElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const touchStartY = useRef<number | null>(null);
  const PULL_THRESHOLD = 60;

  async function refresh() {
    setBusy(true);
    setError(null);
    try {
      const r = await fetch('/api/files', { cache: 'no-store' });
      if (!r.ok) throw new Error(`${r.status}`);
      const body = await r.json();
      setFiles(body.files ?? []);
      setOnline(body.host_online ?? false);
    } catch (e) {
      setError(`Could not reach your storage (${e instanceof Error ? e.message : 'error'}).`);
    } finally {
      setBusy(false);
    }
  }

  async function onFilesPicked(picked: FileList | null) {
    if (!picked || picked.length === 0) return;
    setBusy(true);
    setError(null);
    try {
      for (const f of Array.from(picked)) {
        const resp = await fetch(
          `/api/files?name=${encodeURIComponent(f.name)}&mime=${encodeURIComponent(f.type || 'application/octet-stream')}`,
          { method: 'POST', body: f },
        );
        if (!resp.ok) {
          const t = await resp.text();
          throw new Error(`${resp.status} ${t.slice(0, 120)}`);
        }
      }
      await refresh();
    } catch (e) {
      setError(`Upload failed: ${e instanceof Error ? e.message : 'error'}`);
      setBusy(false);
    } finally {
      if (inputRef.current) inputRef.current.value = '';
    }
  }

  // Pull-to-refresh (mobile Safari). Only fires when the document is at the
  // very top — we don't hijack normal scrolling.
  useEffect(() => {
    const onStart = (e: TouchEvent) => {
      if (window.scrollY > 0) return;
      touchStartY.current = e.touches[0].clientY;
    };
    const onMove = (e: TouchEvent) => {
      if (touchStartY.current == null) return;
      const d = e.touches[0].clientY - touchStartY.current;
      if (d > 0) setPullDist(Math.min(d * 0.5, 90));
    };
    const onEnd = () => {
      if (touchStartY.current == null) return;
      if (pullDist >= PULL_THRESHOLD && !busy) {
        refresh();
      }
      touchStartY.current = null;
      setPullDist(0);
    };
    document.addEventListener('touchstart', onStart, { passive: true });
    document.addEventListener('touchmove', onMove, { passive: true });
    document.addEventListener('touchend', onEnd);
    return () => {
      document.removeEventListener('touchstart', onStart);
      document.removeEventListener('touchmove', onMove);
      document.removeEventListener('touchend', onEnd);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pullDist, busy]);

  return (
    <section ref={containerRef} className="rounded-2xl bg-[color:var(--surface)] border border-[color:var(--border)] p-5 relative">
      {pullDist > 0 && (
        <div
          className="absolute left-0 right-0 -top-2 flex items-center justify-center pointer-events-none"
          style={{ transform: `translateY(${pullDist}px)`, opacity: pullDist / PULL_THRESHOLD }}
        >
          <div className="flex items-center gap-2 text-[color:var(--accent)] text-xs font-medium">
            <RefreshCw size={14} className={pullDist >= PULL_THRESHOLD ? 'animate-spin' : ''} />
            {pullDist >= PULL_THRESHOLD ? 'Release to refresh' : 'Pull to refresh'}
          </div>
        </div>
      )}
      <div className="flex items-center justify-between mb-4">
        <div>
          <h2 className="text-[15px] font-semibold">My files</h2>
          <p className="text-xs text-[color:var(--text-muted)] mt-0.5">
            {online ? `${files.length} file${files.length === 1 ? '' : 's'} on your computer` : 'Your storage is offline'}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <button
            onClick={refresh}
            disabled={busy}
            className="p-2 rounded-lg text-[color:var(--text-muted)] hover:bg-[color:var(--accent-muted)] hover:text-[color:var(--accent)] disabled:opacity-50"
            title="Refresh"
          >
            <RefreshCw size={16} className={busy ? 'animate-spin' : ''} />
          </button>
          <button
            onClick={() => inputRef.current?.click()}
            disabled={busy || !online}
            className="inline-flex items-center gap-1.5 bg-[color:var(--accent)] hover:bg-[color:var(--accent-hover)] disabled:opacity-50 text-white text-xs font-semibold px-3.5 py-2 rounded-lg"
          >
            <Upload size={14} /> Upload
          </button>
          <input
            ref={inputRef}
            type="file"
            multiple
            className="hidden"
            onChange={(e) => onFilesPicked(e.target.files)}
          />
        </div>
      </div>

      {error && (
        <div className="mb-3 px-3 py-2 rounded-md bg-red-50 border border-red-200 text-red-700 text-xs">{error}</div>
      )}

      {!online ? <OfflineState /> : files.length === 0 ? <EmptyState onPick={() => inputRef.current?.click()} /> : (
        <ul className="divide-y divide-[color:var(--border)]">
          {files.map((f) => (
            <li key={f.id} className="flex items-center gap-3 py-3">
              <FileIcon mime={f.mime} />
              <div className="flex-1 min-w-0">
                <div className="text-[13px] font-medium truncate">{f.name}</div>
                <div className="text-[11px] text-[color:var(--text-muted)]">
                  {formatBytes(f.size)} · uploaded {fmtDate(f.created_at)}
                </div>
              </div>
              <a
                href={`/api/files/${encodeURIComponent(f.id)}`}
                className="p-2 rounded-lg text-[color:var(--text-muted)] hover:bg-[color:var(--accent-muted)] hover:text-[color:var(--accent)]"
                title="Download"
                download
              >
                <Download size={16} />
              </a>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function FileIcon({ mime }: { mime: string }) {
  const color =
    mime.startsWith('image/') ? '#8B5CF6'
    : mime.startsWith('video/') ? '#EF4444'
    : mime === 'application/pdf' ? '#DC2626'
    : mime.startsWith('text/') ? '#3B82F6'
    : '#8F93F6';
  const Icon = mime.startsWith('text/') || mime === 'application/pdf' ? FileText : File;
  return (
    <div className="w-9 h-9 rounded-lg flex items-center justify-center" style={{ background: color + '1E' }}>
      <Icon size={16} style={{ color }} />
    </div>
  );
}

function OfflineState() {
  return (
    <div className="text-center py-10">
      <div className="inline-flex items-center justify-center w-14 h-14 rounded-2xl bg-[color:var(--accent-muted)] text-[color:var(--accent)] mb-3">
        <CloudOff size={24} />
      </div>
      <div className="text-sm font-semibold">Your storage is offline</div>
      <div className="text-xs text-[color:var(--text-muted)] mt-1 max-w-sm mx-auto">
        Open the Weeber app on your home computer to bring it online. Your files will appear here automatically.
      </div>
    </div>
  );
}

function EmptyState({ onPick }: { onPick: () => void }) {
  return (
    <div className="text-center py-10">
      <div className="inline-flex items-center justify-center w-14 h-14 rounded-2xl bg-[color:var(--accent-muted)] text-[color:var(--accent)] mb-3">
        <Upload size={24} />
      </div>
      <div className="text-sm font-semibold">No files yet</div>
      <div className="text-xs text-[color:var(--text-muted)] mt-1 mb-4">Upload your first file from here or from the desktop app.</div>
      <button onClick={onPick} className="bg-[color:var(--accent)] hover:bg-[color:var(--accent-hover)] text-white text-xs font-semibold px-4 py-2 rounded-lg inline-flex items-center gap-1.5">
        <Upload size={14} /> Upload a file
      </button>
    </div>
  );
}

function fmtDate(unix: number) {
  return new Date(unix * 1000).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
}

function formatBytes(b: number) {
  if (b < 1024) return `${b} B`;
  const u = ['KB', 'MB', 'GB', 'TB'];
  let v = b / 1024, i = 0;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(1)} ${u[i]}`;
}
