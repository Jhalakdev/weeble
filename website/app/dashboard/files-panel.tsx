'use client';

import { useEffect, useRef, useState, useCallback, useMemo } from 'react';
import { useSearchParams } from 'next/navigation';
import {
  Upload, Download, FileText, CloudOff, RefreshCw, File, Trash2, X,
  Image as ImageIcon, Music, Film, FileCode, Archive, FileSpreadsheet,
  Plus, LayoutGrid, List as ListIcon, MoreVertical, Star,
  Pencil, Info, Filter, Search,
} from 'lucide-react';
import { LiveStorageCard } from '@/components/LiveStorageCard';

type FileItem = { id: string; name: string; size: number; mime: string; created_at: number };
type Stats = { used_bytes: number; allocated_bytes: number; file_count: number };
type TypeKind = 'all' | 'images' | 'videos' | 'audio' | 'documents' | 'archives' | 'other';
type DateRange = 'all' | 'today' | 'week' | 'month' | 'year';

function matchesType(f: FileItem, kind: TypeKind): boolean {
  if (kind === 'all') return true;
  const ext = (f.name.split('.').pop() ?? '').toLowerCase();
  if (kind === 'images') return f.mime.startsWith('image/');
  if (kind === 'videos') return f.mime.startsWith('video/');
  if (kind === 'audio') return f.mime.startsWith('audio/');
  if (kind === 'archives') return ['zip','rar','7z','tar','gz','bz2'].includes(ext);
  if (kind === 'documents') return f.mime === 'application/pdf' || f.mime.startsWith('text/')
      || ['doc','docx','xls','xlsx','ppt','pptx','rtf','odt','ods','odp','csv','md','txt','pages','numbers','key'].includes(ext);
  if (kind === 'other') return !matchesType(f, 'images') && !matchesType(f, 'videos')
      && !matchesType(f, 'audio') && !matchesType(f, 'documents') && !matchesType(f, 'archives');
  return true;
}

function dateCutoff(range: DateRange): number {
  if (range === 'all') return 0;
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  if (range === 'today') return Math.floor(d.getTime() / 1000);
  if (range === 'week') { d.setDate(d.getDate() - 7); return Math.floor(d.getTime() / 1000); }
  if (range === 'month') { d.setMonth(d.getMonth() - 1); return Math.floor(d.getTime() / 1000); }
  if (range === 'year') { d.setFullYear(d.getFullYear() - 1); return Math.floor(d.getTime() / 1000); }
  return 0;
}

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
  const [favorites, setFavorites] = useState<Set<string>>(new Set());
  const [view, setView] = useState<'list' | 'grid'>('list');
  const [openMenu, setOpenMenu] = useState<string | null>(null);
  const [uploads, setUploads] = useState<UploadJob[]>([]);
  const [downloads, setDownloads] = useState<DownloadJob[]>([]);
  const [renameTarget, setRenameTarget] = useState<FileItem | null>(null);
  const [infoTarget, setInfoTarget] = useState<FileItem | null>(null);
  const [typeFilter, setTypeFilter] = useState<TypeKind>('all');
  const [dateFilter, setDateFilter] = useState<DateRange>('all');
  const [dragOver, setDragOver] = useState(false);
  const [localQuery, setLocalQuery] = useState('');
  const inputRef = useRef<HTMLInputElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const touchStartY = useRef<number | null>(null);
  const PULL_THRESHOLD = 60;

  // Search query from the top-bar input is mirrored to the URL via ?q=…,
  // so deep links keep their search and refresh preserves it.
  const searchParams = useSearchParams();
  const urlQuery = (searchParams?.get('q') ?? '').trim();
  const query = (localQuery || urlQuery).toLowerCase();

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

  // Initial stats fetch + auto-poll for cross-device updates.
  useEffect(() => {
    refresh(true);
    const id = setInterval(() => refresh(true), POLL_MS);
    return () => clearInterval(id);
  }, [refresh]);

  // View preference + favorites: persisted in localStorage.
  useEffect(() => {
    try {
      const v = localStorage.getItem('weeber.view');
      if (v === 'grid' || v === 'list') setView(v);
      const f = localStorage.getItem('weeber.favorites');
      if (f) setFavorites(new Set(JSON.parse(f)));
    } catch { /* private mode etc — fine */ }
  }, []);
  useEffect(() => { try { localStorage.setItem('weeber.view', view); } catch {} }, [view]);
  useEffect(() => { try { localStorage.setItem('weeber.favorites', JSON.stringify([...favorites])); } catch {} }, [favorites]);

  function toggleFavorite(id: string) {
    setFavorites((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  }

  async function renameFile(file: FileItem, newName: string) {
    if (!newName.trim() || newName === file.name) { setRenameTarget(null); return; }
    setBusy(true);
    setError(null);
    const before = files;
    setFiles(files.map((x) => x.id === file.id ? { ...x, name: newName } : x));
    try {
      const r = await fetch(`/api/files/${encodeURIComponent(file.id)}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: newName }),
      });
      if (!r.ok) throw new Error(`${r.status}`);
    } catch (e) {
      setFiles(before);
      setError(`Could not rename (${e instanceof Error ? e.message : 'error'}).`);
    } finally {
      setBusy(false);
      setRenameTarget(null);
    }
  }

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

  // Apply search + type + date filters in order. useMemo to avoid
  // re-filtering the entire list on every keystroke unless the inputs
  // actually changed.
  const visibleFiles = useMemo(() => {
    const cutoff = dateCutoff(dateFilter);
    return files
      .filter((f) => !hidden.has(f.id))
      .filter((f) => typeFilter === 'all' || matchesType(f, typeFilter))
      .filter((f) => cutoff === 0 || f.created_at >= cutoff)
      .filter((f) => query === '' || f.name.toLowerCase().includes(query));
  }, [files, hidden, typeFilter, dateFilter, query]);

  return (
    <>
      <section
        ref={containerRef}
        className={`rounded-2xl bg-[color:var(--surface)] border p-5 relative transition ${dragOver ? 'border-[color:var(--accent)] ring-2 ring-[color:var(--accent)]/30' : 'border-[color:var(--border)]'}`}
        onDragOver={(e) => { e.preventDefault(); if (!dragOver) setDragOver(true); }}
        onDragLeave={(e) => { if (e.currentTarget === e.target) setDragOver(false); }}
        onDrop={(e) => {
          e.preventDefault();
          setDragOver(false);
          if (e.dataTransfer.files && e.dataTransfer.files.length > 0) {
            onFilesPicked(e.dataTransfer.files);
          }
        }}
      >
        {dragOver && (
          <div className="absolute inset-3 z-10 rounded-xl bg-[color:var(--accent-muted)] border-2 border-dashed border-[color:var(--accent)] flex items-center justify-center pointer-events-none">
            <div className="text-center">
              <Upload size={32} className="mx-auto mb-2 text-[color:var(--accent)]" />
              <div className="text-sm font-semibold text-[color:var(--accent)]">Drop to upload</div>
            </div>
          </div>
        )}
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

        {/* Storage card — single source of truth, visible on every screen
            size including phone. Uses the same LiveStorageCard as the
            sidebar + account page so values match everywhere. */}
        <div className="mb-4 md:hidden">
          <LiveStorageCard variant="block" />
        </div>

        <div className="flex items-center justify-between mb-4">
          <div>
            <h2 className="text-[15px] font-semibold">My files</h2>
            <p className="text-xs text-[color:var(--text-muted)] mt-0.5">
              {online ? `${visibleFiles.length} file${visibleFiles.length === 1 ? '' : 's'} on your computer` : 'Your storage is offline'}
            </p>
          </div>
          <div className="flex items-center gap-1.5">
            <div className="hidden sm:flex items-center bg-[color:var(--body)] rounded-lg p-0.5">
              <button
                onClick={() => setView('list')}
                aria-label="List view"
                title="List"
                className={`p-1.5 rounded-md transition ${view === 'list' ? 'bg-[color:var(--surface)] text-[color:var(--accent)] shadow-sm' : 'text-[color:var(--text-muted)] hover:text-[color:var(--text)]'}`}
              ><ListIcon size={14} /></button>
              <button
                onClick={() => setView('grid')}
                aria-label="Grid view"
                title="Grid"
                className={`p-1.5 rounded-md transition ${view === 'grid' ? 'bg-[color:var(--surface)] text-[color:var(--accent)] shadow-sm' : 'text-[color:var(--text-muted)] hover:text-[color:var(--text)]'}`}
              ><LayoutGrid size={14} /></button>
            </div>
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

        {/* Filters: search + type chips + date dropdown. Search input
            here is local to this panel; the top-bar global search also
            feeds in via ?q= URL param so deep-linking works. */}
        <div className="mb-3 space-y-2">
          <div className="flex items-center gap-2">
            <div className="relative flex-1">
              <Search size={14} className="absolute left-3 top-1/2 -translate-y-1/2 text-[color:var(--text-muted)]" />
              <input
                value={localQuery || urlQuery}
                onChange={(e) => setLocalQuery(e.target.value)}
                placeholder="Search files…"
                className="w-full h-9 pl-9 pr-3 text-[13px] bg-[color:var(--body)] rounded-lg border border-transparent focus:border-[color:var(--accent)] focus:outline-none"
              />
            </div>
            <select
              value={dateFilter}
              onChange={(e) => setDateFilter(e.target.value as DateRange)}
              className="h-9 px-3 text-[12px] bg-[color:var(--body)] rounded-lg border border-transparent focus:border-[color:var(--accent)] focus:outline-none cursor-pointer"
              aria-label="Date range"
            >
              <option value="all">Any date</option>
              <option value="today">Today</option>
              <option value="week">Past 7 days</option>
              <option value="month">Past 30 days</option>
              <option value="year">Past year</option>
            </select>
          </div>
          <div className="flex items-center gap-1.5 overflow-x-auto -mx-1 px-1 pb-1 scrollbar-thin">
            {([
              { key: 'all', label: 'All', icon: Filter },
              { key: 'images', label: 'Images', icon: ImageIcon },
              { key: 'videos', label: 'Videos', icon: Film },
              { key: 'audio', label: 'Audio', icon: Music },
              { key: 'documents', label: 'Documents', icon: FileText },
              { key: 'archives', label: 'Archives', icon: Archive },
              { key: 'other', label: 'Other', icon: File },
            ] as const).map((c) => {
              const active = typeFilter === c.key;
              const I = c.icon;
              return (
                <button
                  key={c.key}
                  onClick={() => setTypeFilter(c.key)}
                  className={`whitespace-nowrap inline-flex items-center gap-1.5 px-3 py-1 rounded-full text-[11.5px] font-medium transition ${
                    active
                      ? 'bg-[color:var(--accent)] text-white'
                      : 'bg-[color:var(--body)] text-[color:var(--text-muted)] hover:text-[color:var(--text)]'
                  }`}
                ><I size={12} /> {c.label}</button>
              );
            })}
          </div>
        </div>

        {error && (
          <div className="mb-3 px-3 py-2 rounded-md bg-red-50 border border-red-200 text-red-700 text-xs">{error}</div>
        )}

        {!online ? <OfflineState /> : !reachable ? <UnreachableState /> : visibleFiles.length === 0 ? <EmptyState onPick={() => inputRef.current?.click()} /> : view === 'grid' ? (
          <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 gap-3">
            {visibleFiles.map((f) => (
              <FileGridCard
                key={f.id}
                file={f}
                isFav={favorites.has(f.id)}
                isMenuOpen={openMenu === f.id}
                onMenuToggle={() => setOpenMenu(openMenu === f.id ? null : f.id)}
                onMenuClose={() => setOpenMenu(null)}
                onDownload={() => downloadFile(f)}
                onDelete={() => setDeleteTarget(f)}
                onFavorite={() => toggleFavorite(f.id)}
                onRename={() => setRenameTarget(f)}
                onInfo={() => setInfoTarget(f)}
              />
            ))}
          </div>
        ) : (
          <ul className="divide-y divide-[color:var(--border)]">
            {visibleFiles.map((f) => (
              <li key={f.id} className="group flex items-center gap-3 py-3 px-2 -mx-2 rounded-lg hover:bg-[color:var(--accent-muted)]/40 transition">
                <FilePreview mime={f.mime} name={f.name} />
                <div className="flex-1 min-w-0">
                  <div className="text-[13px] font-medium truncate flex items-center gap-1.5">
                    <span className="truncate">{f.name}</span>
                    {favorites.has(f.id) && <Star size={11} className="text-amber-500 flex-shrink-0" fill="currentColor" />}
                  </div>
                  <div className="text-[11px] text-[color:var(--text-muted)]">
                    {formatBytes(f.size)} · uploaded {fmtDate(f.created_at)}
                  </div>
                </div>
                <button
                  onClick={() => toggleFavorite(f.id)}
                  className={`p-2 rounded-lg ${favorites.has(f.id) ? 'text-amber-500' : 'text-[color:var(--text-muted)] hover:text-amber-500'} opacity-0 group-hover:opacity-100 transition`}
                  title={favorites.has(f.id) ? 'Remove from Starred' : 'Add to Starred'}
                  aria-label="Star"
                >
                  <Star size={16} fill={favorites.has(f.id) ? 'currentColor' : 'none'} />
                </button>
                <button
                  onClick={() => downloadFile(f)}
                  className="p-2 rounded-lg text-[color:var(--text-muted)] hover:bg-[color:var(--accent-muted)] hover:text-[color:var(--accent)]"
                  title="Download"
                  aria-label={`Download ${f.name}`}
                >
                  <Download size={16} />
                </button>
                <RowMenu
                  isOpen={openMenu === f.id}
                  onToggle={() => setOpenMenu(openMenu === f.id ? null : f.id)}
                  onClose={() => setOpenMenu(null)}
                  isFav={favorites.has(f.id)}
                  onRename={() => setRenameTarget(f)}
                  onInfo={() => setInfoTarget(f)}
                  onFavorite={() => toggleFavorite(f.id)}
                  onDelete={() => setDeleteTarget(f)}
                />
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
        {renameTarget && (
          <RenameModal
            file={renameTarget}
            busy={busy}
            onCancel={() => setRenameTarget(null)}
            onSave={(name) => renameFile(renameTarget, name)}
          />
        )}
        {infoTarget && (
          <InfoModal file={infoTarget} onClose={() => setInfoTarget(null)} />
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

function FileGridCard({
  file, isFav, isMenuOpen, onMenuToggle, onMenuClose, onDownload, onDelete, onFavorite, onRename, onInfo,
}: {
  file: FileItem;
  isFav: boolean;
  isMenuOpen: boolean;
  onMenuToggle: () => void;
  onMenuClose: () => void;
  onDownload: () => void;
  onDelete: () => void;
  onFavorite: () => void;
  onRename: () => void;
  onInfo: () => void;
}) {
  return (
    <div
      className="group relative flex flex-col rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] overflow-hidden hover:shadow-md hover:border-[color:var(--accent)] transition cursor-pointer"
      onClick={onDownload}
      role="button"
      tabIndex={0}
      aria-label={`Open ${file.name}`}
    >
      <div className="aspect-square flex items-center justify-center bg-[color:var(--body)]">
        <div className="scale-150"><FilePreview mime={file.mime} name={file.name} /></div>
      </div>
      <div className="p-3">
        <div className="flex items-center gap-1.5 mb-0.5">
          <div className="flex-1 min-w-0 text-[12px] font-medium truncate">{file.name}</div>
          {isFav && <Star size={11} className="text-amber-500 flex-shrink-0" fill="currentColor" />}
        </div>
        <div className="text-[10px] text-[color:var(--text-muted)]">{formatBytes(file.size)}</div>
      </div>
      <button
        onClick={(e) => { e.stopPropagation(); onMenuToggle(); }}
        className="absolute top-2 right-2 p-1.5 rounded-lg bg-[color:var(--surface)]/80 backdrop-blur text-[color:var(--text-muted)] hover:text-[color:var(--text)] opacity-0 group-hover:opacity-100 transition"
        aria-label="More"
      >
        <MoreVertical size={14} />
      </button>
      {isMenuOpen && (
        <div
          className="absolute top-10 right-2 z-20 w-44 rounded-lg bg-[color:var(--surface)] border border-[color:var(--border)] shadow-lg py-1 text-[12px]"
          onClick={(e) => e.stopPropagation()}
        >
          <button onClick={() => { onDownload(); onMenuClose(); }} className="w-full text-left px-3 py-1.5 hover:bg-[color:var(--accent-muted)] flex items-center gap-2"><Download size={12} /> Download</button>
          <button onClick={() => { onRename(); onMenuClose(); }} className="w-full text-left px-3 py-1.5 hover:bg-[color:var(--accent-muted)] flex items-center gap-2"><Pencil size={12} /> Rename</button>
          <button onClick={() => { onFavorite(); onMenuClose(); }} className="w-full text-left px-3 py-1.5 hover:bg-[color:var(--accent-muted)] flex items-center gap-2">
            <Star size={12} className={isFav ? 'text-amber-500' : ''} fill={isFav ? 'currentColor' : 'none'} />
            {isFav ? 'Remove from Starred' : 'Add to Starred'}
          </button>
          <button onClick={() => { onInfo(); onMenuClose(); }} className="w-full text-left px-3 py-1.5 hover:bg-[color:var(--accent-muted)] flex items-center gap-2"><Info size={12} /> File info</button>
          <div className="my-1 border-t border-[color:var(--border)]" />
          <button onClick={() => { onDelete(); onMenuClose(); }} className="w-full text-left px-3 py-1.5 hover:bg-red-50 hover:text-red-600 flex items-center gap-2"><Trash2 size={12} /> Delete</button>
        </div>
      )}
    </div>
  );
}

function RowMenu({
  isOpen, onToggle, onClose, isFav, onRename, onInfo, onFavorite, onDelete,
}: {
  isOpen: boolean;
  onToggle: () => void;
  onClose: () => void;
  isFav: boolean;
  onRename: () => void;
  onInfo: () => void;
  onFavorite: () => void;
  onDelete: () => void;
}) {
  return (
    <div className="relative">
      <button
        onClick={onToggle}
        className="p-2 rounded-lg text-[color:var(--text-muted)] hover:bg-[color:var(--accent-muted)] hover:text-[color:var(--accent)]"
        aria-label="More"
        title="More"
      >
        <MoreVertical size={16} />
      </button>
      {isOpen && (
        <div
          className="absolute right-0 top-full mt-1 z-20 w-44 rounded-lg bg-[color:var(--surface)] border border-[color:var(--border)] shadow-lg py-1 text-[12px]"
          onClick={(e) => e.stopPropagation()}
        >
          <button onClick={() => { onRename(); onClose(); }} className="w-full text-left px-3 py-1.5 hover:bg-[color:var(--accent-muted)] flex items-center gap-2"><Pencil size={12} /> Rename</button>
          <button onClick={() => { onFavorite(); onClose(); }} className="w-full text-left px-3 py-1.5 hover:bg-[color:var(--accent-muted)] flex items-center gap-2">
            <Star size={12} className={isFav ? 'text-amber-500' : ''} fill={isFav ? 'currentColor' : 'none'} />
            {isFav ? 'Remove from Starred' : 'Add to Starred'}
          </button>
          <button onClick={() => { onInfo(); onClose(); }} className="w-full text-left px-3 py-1.5 hover:bg-[color:var(--accent-muted)] flex items-center gap-2"><Info size={12} /> File info</button>
          <div className="my-1 border-t border-[color:var(--border)]" />
          <button onClick={() => { onDelete(); onClose(); }} className="w-full text-left px-3 py-1.5 hover:bg-red-50 hover:text-red-600 flex items-center gap-2"><Trash2 size={12} /> Delete</button>
        </div>
      )}
    </div>
  );
}

function RenameModal({ file, busy, onCancel, onSave }: { file: FileItem; busy: boolean; onCancel: () => void; onSave: (name: string) => void }) {
  const [name, setName] = useState(file.name);
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={onCancel} role="dialog" aria-modal="true">
      <div className="w-full max-w-sm rounded-2xl bg-[color:var(--surface)] border border-[color:var(--border)] p-5 shadow-xl" onClick={(e) => e.stopPropagation()}>
        <h3 className="text-[15px] font-semibold mb-3">Rename file</h3>
        <input
          autoFocus
          value={name}
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter' && !busy) onSave(name); }}
          className="w-full h-10 px-3 text-[13px] bg-[color:var(--body)] rounded-lg border border-transparent focus:border-[color:var(--accent)] focus:outline-none mb-4"
        />
        <div className="flex justify-end gap-2">
          <button onClick={onCancel} disabled={busy} className="px-4 py-2 text-[12px] text-[color:var(--text-muted)] hover:text-[color:var(--text)]">Cancel</button>
          <button onClick={() => onSave(name)} disabled={busy || !name.trim() || name === file.name} className="px-4 py-2 text-[12px] font-semibold bg-[color:var(--accent)] hover:bg-[color:var(--accent-hover)] disabled:opacity-50 text-white rounded-lg">Save</button>
        </div>
      </div>
    </div>
  );
}

function InfoModal({ file, onClose }: { file: FileItem; onClose: () => void }) {
  const ext = (file.name.split('.').pop() ?? '').toLowerCase();
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={onClose} role="dialog" aria-modal="true">
      <div className="w-full max-w-sm rounded-2xl bg-[color:var(--surface)] border border-[color:var(--border)] p-5 shadow-xl" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between mb-4">
          <h3 className="text-[15px] font-semibold">File info</h3>
          <button onClick={onClose} className="text-[color:var(--text-muted)] hover:text-[color:var(--text)] p-1" aria-label="Close"><X size={16} /></button>
        </div>
        <div className="flex items-center gap-3 mb-4">
          <FilePreview mime={file.mime} name={file.name} />
          <div className="min-w-0">
            <div className="text-[13px] font-medium truncate">{file.name}</div>
            <div className="text-[11px] text-[color:var(--text-muted)]">{file.mime}</div>
          </div>
        </div>
        <dl className="text-[12px] space-y-2">
          <InfoRow label="Type" value={ext.toUpperCase() || '—'} />
          <InfoRow label="Size" value={formatBytes(file.size)} />
          <InfoRow label="Uploaded" value={fmtFullDate(file.created_at)} />
          <InfoRow label="ID" value={<code className="text-[10px] break-all">{file.id}</code>} />
        </dl>
      </div>
    </div>
  );
}

function InfoRow({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex justify-between items-start gap-3">
      <dt className="text-[color:var(--text-muted)] uppercase tracking-wider text-[10px] pt-0.5">{label}</dt>
      <dd className="text-right text-[color:var(--text)] flex-1 min-w-0">{value}</dd>
    </div>
  );
}

function fmtFullDate(unix: number) {
  return new Date(unix * 1000).toLocaleString('en-US', {
    year: 'numeric', month: 'short', day: 'numeric',
    hour: 'numeric', minute: '2-digit',
  });
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
