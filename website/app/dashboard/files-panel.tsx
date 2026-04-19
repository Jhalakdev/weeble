'use client';

import { useEffect, useRef, useState, useCallback } from 'react';
import {
  Upload, Download, FileText, CloudOff, RefreshCw, File, Trash2, X,
  Image as ImageIcon, Music, Film, FileCode, Archive, FileSpreadsheet,
  Plus, HardDrive,
} from 'lucide-react';

type FileItem = { id: string; name: string; size: number; mime: string; created_at: number };
type Stats = { used_bytes: number; allocated_bytes: number; file_count: number };

type UploadJob = {
  id: string;
  name: string;
  size: number;
  uploaded: number;
  status: 'uploading' | 'done' | 'error';
  error?: string;
};

type DownloadJob = {
  id: string;
  name: string;
  total: number;
  received: number;
  status: 'downloading' | 'done' | 'error';
  error?: string;
};

const POLL_MS = 4000; // auto-refresh interval — keeps the list in sync when other devices upload

export function FilesPanel({
  initialFiles, hostOnline,
}: {
  initialFiles: FileItem[];
  hostOnline: boolean;
}) {
  const [files, setFiles] = useState<FileItem[]>(initialFiles);
  const [stats, setStats] = useState<Stats | null>(null);
  const [online, setOnline] = useState(hostOnline);
  const [reachable, setReachable] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pullDist, setPullDist] = useState(0);
  const [deleteTarget, setDeleteTarget] = useState<FileItem | null>(null);
  const [hidden, setHidden] = useState<Set<string>>(new Set());
  const [uploads, setUploads] = useState<UploadJob[]>([]);
  const [downloads, setDownloads] = useState<DownloadJob[]>([]);
  const inputRef = useRef<HTMLInputElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const touchStartY = useRef<number | null>(null);
  const PULL_THRESHOLD = 60;

  const refresh = useCallback(async (silent = false) => {
    if (!silent) setBusy(true);
    setError(null);
    try {
      const r = await fetch('/api/files', { cache: 'no-store' });
      if (!r.ok) throw new Error(`${r.status}`);
      const body = await r.json();
      setFiles(body.files ?? []);
      setOnline(body.host_online ?? false);
      setReachable(body.reachable ?? true);
      setStats(body.stats ?? null);
    } catch (e) {
      if (!silent) setError(`Could not reach your storage (${e instanceof Error ? e.message : 'error'}).`);
    } finally {
      if (!silent) setBusy(false);
    }
  }, []);

  // Initial stats fetch + auto-poll for cross-device updates (phone uploads
  // appear on web, web uploads appear on phone, etc.).
  useEffect(() => {
    refresh(true);
    const id = setInterval(() => refresh(true), POLL_MS);
    return () => clearInterval(id);
  }, [refresh]);

  async function deleteFromHost(file: FileItem) {
    setBusy(true);
    setError(null);
    const before = files;
    setFiles(files.filter((x) => x.id !== file.id));
    try {
      const r = await fetch(`/api/files/${encodeURIComponent(file.id)}`, { method: 'DELETE' });
      if (!r.ok) throw new Error(`${r.status}`);
    } catch (e) {
      setFiles(before);
      setError(`Could not delete (${e instanceof Error ? e.message : 'error'}).`);
    } finally {
      setBusy(false);
      setDeleteTarget(null);
    }
  }

  function hideOnlyHere(file: FileItem) {
    setHidden(new Set([...hidden, file.id]));
    setDeleteTarget(null);
  }

  // Upload via XHR so we get real upload-progress events. fetch() doesn't
  // expose upload progress in browsers reliably, so XHR is the right tool.
  function uploadOne(f: File): Promise<void> {
    return new Promise((resolve, reject) => {
      const jobId = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
      setUploads((prev) => [...prev, { id: jobId, name: f.name, size: f.size, uploaded: 0, status: 'uploading' }]);
      const xhr = new XMLHttpRequest();
      xhr.open(
        'POST',
        `/api/files?name=${encodeURIComponent(f.name)}&mime=${encodeURIComponent(f.type || 'application/octet-stream')}`,
      );
      xhr.upload.onprogress = (ev) => {
        if (!ev.lengthComputable) return;
        setUploads((prev) => prev.map((u) => u.id === jobId ? { ...u, uploaded: ev.loaded } : u));
      };
      xhr.onload = () => {
        if (xhr.status >= 200 && xhr.status < 300) {
          setUploads((prev) => prev.map((u) => u.id === jobId ? { ...u, uploaded: u.size, status: 'done' } : u));
          // Drop the job from the visible queue after a moment so the row doesn't linger.
          setTimeout(() => setUploads((prev) => prev.filter((u) => u.id !== jobId)), 1200);
          resolve();
        } else {
          const msg = `${xhr.status} ${xhr.responseText.slice(0, 120)}`;
          setUploads((prev) => prev.map((u) => u.id === jobId ? { ...u, status: 'error', error: msg } : u));
          reject(new Error(msg));
        }
      };
      xhr.onerror = () => {
        setUploads((prev) => prev.map((u) => u.id === jobId ? { ...u, status: 'error', error: 'network' } : u));
        reject(new Error('network'));
      };
      xhr.send(f);
    });
  }

  async function onFilesPicked(picked: FileList | null) {
    if (!picked || picked.length === 0) return;
    setError(null);
    try {
      for (const f of Array.from(picked)) {
        await uploadOne(f);
      }
      await refresh(true);
    } catch (e) {
      setError(`Upload failed: ${e instanceof Error ? e.message : 'error'}`);
    } finally {
      if (inputRef.current) inputRef.current.value = '';
    }
  }

  // Streamed download using fetch + ReadableStream so we can show progress.
  // Falls back to the simple <a download> if the file is small.
  async function downloadFile(file: FileItem) {
    const jobId = `${file.id}-${Date.now()}`;
    setDownloads((prev) => [...prev, { id: jobId, name: file.name, total: file.size, received: 0, status: 'downloading' }]);
    try {
      const resp = await fetch(`/api/files/${encodeURIComponent(file.id)}`);
      if (!resp.ok || !resp.body) throw new Error(`${resp.status}`);
      const total = Number(resp.headers.get('content-length') || file.size || 0);
      const reader = resp.body.getReader();
      const chunks: Uint8Array[] = [];
      let received = 0;
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        if (value) {
          chunks.push(value);
          received += value.byteLength;
          setDownloads((prev) => prev.map((d) => d.id === jobId ? { ...d, received, total } : d));
        }
      }
      const blob = new Blob(chunks as BlobPart[], { type: file.mime });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = file.name;
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
      setDownloads((prev) => prev.map((d) => d.id === jobId ? { ...d, status: 'done' } : d));
      setTimeout(() => setDownloads((prev) => prev.filter((d) => d.id !== jobId)), 1500);
    } catch (e) {
      setDownloads((prev) => prev.map((d) => d.id === jobId ? { ...d, status: 'error', error: String(e) } : d));
    }
  }

  // Pull-to-refresh
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
      if (pullDist >= PULL_THRESHOLD && !busy) refresh();
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
  }, [pullDist, busy, refresh]);

  const visibleFiles = files.filter((f) => !hidden.has(f.id));
  const usedBytes = stats?.used_bytes ?? visibleFiles.reduce((s, f) => s + f.size, 0);
  // Cap = whatever the user allocated on their host. We do NOT sell storage —
  // if they want more, they bump the slider on the host (not a checkout).
  const cap = stats?.allocated_bytes ?? 0;

  return (
    <>
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

        {/* Storage card — visible on every screen size, including phone */}
        {online && reachable && (
          <StorageCard usedBytes={usedBytes} capBytes={cap} fileCount={stats?.file_count ?? visibleFiles.length} />
        )}

        <div className="flex items-center justify-between mb-4">
          <div>
            <h2 className="text-[15px] font-semibold">My files</h2>
            <p className="text-xs text-[color:var(--text-muted)] mt-0.5">
              {online ? `${visibleFiles.length} file${visibleFiles.length === 1 ? '' : 's'} on your computer` : 'Your storage is offline'}
            </p>
          </div>
          <div className="flex items-center gap-2">
            <button
              onClick={() => refresh()}
              disabled={busy}
              className="p-2 rounded-lg text-[color:var(--text-muted)] hover:bg-[color:var(--accent-muted)] hover:text-[color:var(--accent)] disabled:opacity-50"
              title="Refresh"
              aria-label="Refresh"
            >
              <RefreshCw size={16} className={busy ? 'animate-spin' : ''} />
            </button>
            <button
              onClick={() => inputRef.current?.click()}
              disabled={!online}
              className="hidden sm:inline-flex items-center gap-1.5 bg-[color:var(--accent)] hover:bg-[color:var(--accent-hover)] disabled:opacity-50 text-white text-xs font-semibold px-3.5 py-2 rounded-lg"
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

        {!online ? <OfflineState /> : !reachable ? <UnreachableState /> : visibleFiles.length === 0 ? <EmptyState onPick={() => inputRef.current?.click()} /> : (
          <ul className="divide-y divide-[color:var(--border)]">
            {visibleFiles.map((f) => (
              <li key={f.id} className="flex items-center gap-3 py-3">
                <FilePreview mime={f.mime} name={f.name} />
                <div className="flex-1 min-w-0">
                  <div className="text-[13px] font-medium truncate">{f.name}</div>
                  <div className="text-[11px] text-[color:var(--text-muted)]">
                    {formatBytes(f.size)} · uploaded {fmtDate(f.created_at)}
                  </div>
                </div>
                <button
                  onClick={() => downloadFile(f)}
                  className="p-2 rounded-lg text-[color:var(--text-muted)] hover:bg-[color:var(--accent-muted)] hover:text-[color:var(--accent)]"
                  title="Download"
                  aria-label={`Download ${f.name}`}
                >
                  <Download size={16} />
                </button>
                <button
                  onClick={() => setDeleteTarget(f)}
                  className="p-2 rounded-lg text-[color:var(--text-muted)] hover:bg-red-50 hover:text-red-600"
                  title="Delete"
                  aria-label={`Delete ${f.name}`}
                >
                  <Trash2 size={16} />
                </button>
              </li>
            ))}
          </ul>
        )}

        {deleteTarget && (
          <DeleteModal
            file={deleteTarget}
            busy={busy}
            onCancel={() => setDeleteTarget(null)}
            onDeleteFromHost={() => deleteFromHost(deleteTarget)}
            onHideOnlyHere={() => hideOnlyHere(deleteTarget)}
          />
        )}
      </section>

      {/* Upload + download progress overlay */}
      <TransferOverlay
        uploads={uploads}
        downloads={downloads}
        onClearUpload={(id) => setUploads((u) => u.filter((x) => x.id !== id))}
        onClearDownload={(id) => setDownloads((d) => d.filter((x) => x.id !== id))}
      />

      {/* Floating action button — visible on phone, where the inline button is hidden */}
      <button
        onClick={() => inputRef.current?.click()}
        disabled={!online}
        className="sm:hidden fixed right-5 bottom-5 z-40 w-14 h-14 rounded-full text-white shadow-lg disabled:opacity-50 flex items-center justify-center"
        style={{ background: 'linear-gradient(135deg, #8F93F6 0%, #6E74F2 100%)' }}
        aria-label="Upload"
      >
        <Plus size={26} />
      </button>
    </>
  );
}

function StorageCard({ usedBytes, capBytes, fileCount }: { usedBytes: number; capBytes: number; fileCount: number }) {
  const hasCap = capBytes > 0;
  const pct = hasCap ? Math.min(100, (usedBytes / capBytes) * 100) : 0;
  return (
    <div className="mb-4 rounded-xl border border-[color:var(--border)] bg-[color:var(--accent-muted)] p-4">
      <div className="flex items-center gap-2 mb-2">
        <div className="w-7 h-7 rounded-lg bg-white/70 dark:bg-black/20 flex items-center justify-center text-[color:var(--accent)]">
          <HardDrive size={14} />
        </div>
        <div className="flex-1 min-w-0">
          <div className="text-[12px] font-semibold text-[color:var(--text)]">Storage</div>
          <div className="text-[10px] text-[color:var(--text-muted)]">
            {hasCap
              ? `${formatBytes(usedBytes)} of ${formatBytes(capBytes)} used · ${fileCount} file${fileCount === 1 ? '' : 's'}`
              : `${formatBytes(usedBytes)} used · ${fileCount} file${fileCount === 1 ? '' : 's'}`}
          </div>
        </div>
        {hasCap && (
          <div className="text-[11px] font-semibold text-[color:var(--accent)]">{pct.toFixed(0)}%</div>
        )}
      </div>
      {hasCap && (
        <div className="w-full h-1.5 rounded-full bg-white/60 dark:bg-black/20 overflow-hidden">
          <div
            className="h-full rounded-full"
            style={{ width: `${pct}%`, background: 'linear-gradient(90deg, #8F93F6 0%, #6E74F2 100%)', transition: 'width 300ms ease' }}
          />
        </div>
      )}
      <div className="mt-2 text-[10px] text-[color:var(--text-muted)] leading-relaxed">
        Storage lives on your computer. To make room for more files, open the Weeber app on your computer → <span className="font-medium">Increase storage</span>.
      </div>
    </div>
  );
}

function TransferOverlay({
  uploads, downloads, onClearUpload, onClearDownload,
}: {
  uploads: UploadJob[];
  downloads: DownloadJob[];
  onClearUpload: (id: string) => void;
  onClearDownload: (id: string) => void;
}) {
  if (uploads.length === 0 && downloads.length === 0) return null;
  return (
    <div className="fixed bottom-4 left-4 right-4 sm:left-auto sm:right-4 sm:bottom-4 sm:w-[360px] z-30 space-y-2">
      {uploads.map((u) => (
        <ProgressRow
          key={u.id}
          icon={<Upload size={14} />}
          name={u.name}
          done={u.uploaded}
          total={u.size}
          status={u.status}
          error={u.error}
          onClose={u.status !== 'uploading' ? () => onClearUpload(u.id) : undefined}
        />
      ))}
      {downloads.map((d) => (
        <ProgressRow
          key={d.id}
          icon={<Download size={14} />}
          name={d.name}
          done={d.received}
          total={d.total}
          status={d.status === 'downloading' ? 'uploading' : d.status} // reuse styling
          error={d.error}
          onClose={d.status !== 'downloading' ? () => onClearDownload(d.id) : undefined}
        />
      ))}
    </div>
  );
}

function ProgressRow({
  icon, name, done, total, status, error, onClose,
}: {
  icon: React.ReactNode;
  name: string;
  done: number;
  total: number;
  status: 'uploading' | 'done' | 'error';
  error?: string;
  onClose?: () => void;
}) {
  const pct = total > 0 ? Math.min(100, (done / total) * 100) : (status === 'done' ? 100 : 0);
  return (
    <div className="rounded-xl bg-[color:var(--surface)] border border-[color:var(--border)] shadow-lg p-3">
      <div className="flex items-center gap-2 mb-1.5">
        <div className="w-7 h-7 rounded-lg bg-[color:var(--accent-muted)] text-[color:var(--accent)] flex items-center justify-center">{icon}</div>
        <div className="flex-1 min-w-0">
          <div className="text-[12px] font-medium truncate">{name}</div>
          <div className="text-[10px] text-[color:var(--text-muted)]">
            {status === 'error' ? `Error: ${error ?? 'failed'}` : status === 'done' ? 'Complete' : `${formatBytes(done)} / ${formatBytes(total)} · ${pct.toFixed(0)}%`}
          </div>
        </div>
        {onClose && (
          <button onClick={onClose} className="text-[color:var(--text-muted)] hover:text-[color:var(--text)] p-1" aria-label="Dismiss"><X size={14} /></button>
        )}
      </div>
      <div className="w-full h-1 rounded-full bg-[color:var(--border)] overflow-hidden">
        <div
          className="h-full rounded-full"
          style={{
            width: `${pct}%`,
            background: status === 'error' ? '#EF4444' : 'linear-gradient(90deg, #8F93F6 0%, #6E74F2 100%)',
            transition: 'width 200ms ease',
          }}
        />
      </div>
    </div>
  );
}

function DeleteModal({
  file, busy, onCancel, onDeleteFromHost, onHideOnlyHere,
}: {
  file: FileItem;
  busy: boolean;
  onCancel: () => void;
  onDeleteFromHost: () => void;
  onHideOnlyHere: () => void;
}) {
  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
      onClick={onCancel}
      role="dialog"
      aria-modal="true"
    >
      <div
        className="w-full max-w-sm rounded-2xl bg-[color:var(--surface)] border border-[color:var(--border)] p-5 shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <h3 className="text-[15px] font-semibold mb-1">Delete &ldquo;{file.name}&rdquo;?</h3>
        <p className="text-xs text-[color:var(--text-muted)] mb-4 leading-relaxed">
          You can remove this file from your Weeber storage (it disappears from
          all your devices) or just hide it from this page.
        </p>
        <div className="flex flex-col gap-2">
          <button
            onClick={onDeleteFromHost}
            disabled={busy}
            className="w-full inline-flex items-center justify-center gap-1.5 bg-red-600 hover:bg-red-700 disabled:opacity-50 text-white text-xs font-semibold px-3.5 py-2.5 rounded-lg"
          >
            <Trash2 size={14} /> Delete from Weeber (all devices)
          </button>
          <button
            onClick={onHideOnlyHere}
            disabled={busy}
            className="w-full inline-flex items-center justify-center gap-1.5 bg-[color:var(--surface)] border border-[color:var(--border)] hover:bg-[color:var(--accent-muted)] text-[color:var(--text)] text-xs font-medium px-3.5 py-2.5 rounded-lg"
          >
            Just hide it from this page
          </button>
          <button
            onClick={onCancel}
            disabled={busy}
            className="w-full text-xs text-[color:var(--text-muted)] py-1.5 hover:text-[color:var(--text)]"
          >
            Cancel
          </button>
        </div>
      </div>
    </div>
  );
}

// Per-mime preview tile — distinct visual per file family so the list reads at a glance.
// Image: purple gradient with image icon (real thumbnails come in a follow-up that
// adds a /thumb endpoint to the host).
// PDF: red paper with PDF label band.
// Audio: pink with note icon.
// Video: dark with play overlay.
// Code/text: blue.
// Spreadsheet: green.
// Archive: amber.
function FilePreview({ mime, name }: { mime: string; name: string }) {
  const ext = name.split('.').pop()?.toLowerCase() ?? '';
  const kind = mimeKind(mime, ext);

  const styles: Record<string, { bg: string; fg: string; label?: string; icon: React.ReactNode }> = {
    image: {
      bg: 'linear-gradient(135deg, #C4B5FD 0%, #8B5CF6 100%)',
      fg: '#fff',
      icon: <ImageIcon size={16} />,
    },
    pdf: {
      bg: '#FEE2E2',
      fg: '#DC2626',
      label: 'PDF',
      icon: <FileText size={16} />,
    },
    audio: {
      bg: 'linear-gradient(135deg, #FBCFE8 0%, #EC4899 100%)',
      fg: '#fff',
      icon: <Music size={16} />,
    },
    video: {
      bg: 'linear-gradient(135deg, #1F2937 0%, #4B5563 100%)',
      fg: '#fff',
      icon: <Film size={16} />,
    },
    spreadsheet: {
      bg: '#D1FAE5',
      fg: '#059669',
      label: ext.toUpperCase().slice(0, 4),
      icon: <FileSpreadsheet size={16} />,
    },
    archive: {
      bg: '#FEF3C7',
      fg: '#D97706',
      label: ext.toUpperCase().slice(0, 4),
      icon: <Archive size={16} />,
    },
    code: {
      bg: '#DBEAFE',
      fg: '#2563EB',
      label: ext.toUpperCase().slice(0, 4),
      icon: <FileCode size={16} />,
    },
    text: {
      bg: '#DBEAFE',
      fg: '#2563EB',
      icon: <FileText size={16} />,
    },
    other: {
      bg: '#E5E7EB',
      fg: '#6B7280',
      icon: <File size={16} />,
    },
  };

  const s = styles[kind] ?? styles.other;
  return (
    <div className="relative w-10 h-10 rounded-lg overflow-hidden flex items-center justify-center" style={{ background: s.bg, color: s.fg }}>
      {s.icon}
      {s.label && (
        <div
          className="absolute bottom-0 left-0 right-0 text-[8px] font-bold tracking-wider text-center py-0.5"
          style={{ background: s.fg, color: '#fff' }}
        >
          {s.label}
        </div>
      )}
    </div>
  );
}

function mimeKind(mime: string, ext: string): string {
  if (mime.startsWith('image/')) return 'image';
  if (mime === 'application/pdf') return 'pdf';
  if (mime.startsWith('audio/')) return 'audio';
  if (mime.startsWith('video/')) return 'video';
  if (mime.startsWith('text/')) return 'text';
  if (['xls', 'xlsx', 'csv', 'ods', 'numbers'].includes(ext)) return 'spreadsheet';
  if (['zip', 'rar', '7z', 'tar', 'gz', 'bz2'].includes(ext)) return 'archive';
  if (['js', 'ts', 'tsx', 'jsx', 'py', 'go', 'rs', 'java', 'c', 'cpp', 'h', 'sh', 'json', 'yaml', 'yml', 'html', 'css', 'sql', 'rb', 'php'].includes(ext)) return 'code';
  return 'other';
}

function UnreachableState() {
  return (
    <div className="text-center py-10 px-4">
      <div className="inline-flex items-center justify-center w-14 h-14 rounded-2xl bg-amber-50 text-amber-700 mb-3">
        <CloudOff size={24} />
      </div>
      <div className="text-sm font-semibold">Storage online — but not reachable from the internet</div>
      <div className="text-xs text-[color:var(--text-muted)] mt-1 mb-3 max-w-md mx-auto leading-relaxed">
        Your home computer is online and registered, but the relay can&rsquo;t reach it.
        It usually clears in a few seconds — pull to refresh.
      </div>
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
