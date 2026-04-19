'use client';

import { useEffect, useRef, useState, useCallback, useMemo } from 'react';
import { useSearchParams } from 'next/navigation';
import {
  Upload, Download, FileText, CloudOff, RefreshCw, File, Trash2, X,
  Image as ImageIcon, Music, Film, FileCode, Archive, FileSpreadsheet,
  Plus, LayoutGrid, List as ListIcon, MoreVertical, Star,
  Pencil, Info, Filter, Search, Folder as FolderIcon, FolderPlus,
  ChevronRight, Home, Move, Copy as CopyIcon, CheckSquare,
} from 'lucide-react';
import { LiveStorageCard } from '@/components/LiveStorageCard';

type FileItem = { id: string; name: string; size: number; mime: string; created_at: number; parent_id?: string | null };
type Crumb = { id: string; name: string };
type Stats = { used_bytes: number; allocated_bytes: number; file_count: number };
const FOLDER_MIME = 'inode/directory';
function isFolder(f: FileItem) { return f.mime === FOLDER_MIME; }
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
  const [previewTarget, setPreviewTarget] = useState<FileItem | null>(null);
  const [showFabMenu, setShowFabMenu] = useState(false);
  const [typeFilter, setTypeFilter] = useState<TypeKind>('all');
  const [dateFilter, setDateFilter] = useState<DateRange>('all');
  const [dragOver, setDragOver] = useState(false);
  const [localQuery, setLocalQuery] = useState('');
  // Folder navigation: currentFolder is the id of the folder we're inside
  // (null/empty = root). path is the breadcrumb chain from server.
  const [currentFolder, setCurrentFolder] = useState<string | null>(null);
  const [path, setPath] = useState<Crumb[]>([]);
  // Multi-select. selected.size > 0 reveals the bulk action bar.
  const [selected, setSelected] = useState<Set<string>>(new Set());
  // Modals for folder operations.
  const [showNewFolder, setShowNewFolder] = useState(false);
  const [movePicker, setMovePicker] = useState<{ ids: string[] } | null>(null);
  const [dragRowId, setDragRowId] = useState<string | null>(null);
  const [dropTargetFolderId, setDropTargetFolderId] = useState<string | null>(null);
  // Lazy-load: render 12 rows at a time and grow as the sentinel
  // scrolls into view. Resets whenever the filtered set changes.
  const [visibleCount, setVisibleCount] = useState(12);
  const sentinelRef = useRef<HTMLDivElement>(null);
  const PAGE = 12;
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
      const qs = currentFolder ? `?parent=${encodeURIComponent(currentFolder)}` : '';
      const r = await fetch(`/api/files${qs}`, { cache: 'no-store' });
      if (!r.ok) throw new Error(`${r.status}`);
      const body = await r.json();
      setFiles(body.files ?? []);
      setPath(body.path ?? []);
      setOnline(body.host_online ?? false);
      setReachable(body.reachable ?? true);
      setStats(body.stats ?? null);
    } catch (e) {
      if (!silent) setError(`Could not reach your storage (${e instanceof Error ? e.message : 'error'}).`);
    } finally {
      if (!silent) setBusy(false);
    }
  }, [currentFolder]);

  // Refetch on folder change + auto-poll inside the current folder.
  useEffect(() => {
    refresh(true);
    const id = setInterval(() => refresh(true), POLL_MS);
    return () => clearInterval(id);
  }, [refresh]);

  // Clear selection when changing folders.
  useEffect(() => { setSelected(new Set()); }, [currentFolder]);

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

  // ---- Folder / move / copy / bulk action handlers ----

  async function createFolder(name: string) {
    const trimmed = name.trim();
    if (!trimmed) { setShowNewFolder(false); return; }
    setBusy(true); setError(null);
    try {
      const r = await fetch('/api/folders', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: trimmed, parent_id: currentFolder ?? '' }),
      });
      if (!r.ok) throw new Error(`${r.status}`);
      await refresh(true);
    } catch (e) {
      setError(`Could not create folder (${e instanceof Error ? e.message : 'error'}).`);
    } finally {
      setBusy(false); setShowNewFolder(false);
    }
  }

  function enterFolder(folder: FileItem) {
    setCurrentFolder(folder.id);
  }

  function navigateTo(folderId: string | null) {
    setCurrentFolder(folderId);
  }

  async function moveFiles(ids: string[], targetParentId: string | null) {
    setBusy(true); setError(null);
    try {
      const r = await fetch('/api/files/bulk', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'move', ids, parent_id: targetParentId ?? '' }),
      });
      if (!r.ok) throw new Error(`${r.status}`);
      setSelected(new Set());
      setMovePicker(null);
      await refresh(true);
    } catch (e) {
      setError(`Move failed (${e instanceof Error ? e.message : 'error'}).`);
    } finally {
      setBusy(false);
    }
  }

  async function copyFile(file: FileItem) {
    setBusy(true); setError(null);
    try {
      const r = await fetch(`/api/files/${encodeURIComponent(file.id)}/copy`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({}),
      });
      if (!r.ok) throw new Error(`${r.status}`);
      await refresh(true);
    } catch (e) {
      setError(`Copy failed (${e instanceof Error ? e.message : 'error'}).`);
    } finally {
      setBusy(false);
    }
  }

  async function bulkDelete(ids: string[]) {
    setBusy(true); setError(null);
    const before = files;
    setFiles(files.filter((x) => !ids.includes(x.id)));
    setSelected(new Set());
    try {
      const r = await fetch('/api/files/bulk', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'delete', ids }),
      });
      if (!r.ok) throw new Error(`${r.status}`);
    } catch (e) {
      setFiles(before);
      setError(`Bulk delete failed (${e instanceof Error ? e.message : 'error'}).`);
    } finally {
      setBusy(false);
    }
  }

  function toggleSelect(id: string) {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  }

  function selectAll() { setSelected(new Set(files.map((f) => f.id))); }
  function clearSelection() { setSelected(new Set()); }

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
      const parentParam = currentFolder ? `&parent=${encodeURIComponent(currentFolder)}` : '';
      xhr.open(
        'POST',
        `/api/files?name=${encodeURIComponent(f.name)}&mime=${encodeURIComponent(f.type || 'application/octet-stream')}${parentParam}`,
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

  // Apply search + type + date filters; folders ALWAYS come first, then
  // files, both sorted alphabetically (Google Drive convention). Folders
  // ignore the type filter since they aren't typed.
  const visibleFiles = useMemo(() => {
    const cutoff = dateCutoff(dateFilter);
    const filtered = files
      .filter((f) => !hidden.has(f.id))
      .filter((f) => isFolder(f) || typeFilter === 'all' || matchesType(f, typeFilter))
      .filter((f) => cutoff === 0 || f.created_at >= cutoff)
      .filter((f) => query === '' || f.name.toLowerCase().includes(query));
    return filtered.sort((a, b) => {
      const fa = isFolder(a), fb = isFolder(b);
      if (fa !== fb) return fa ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
  }, [files, hidden, typeFilter, dateFilter, query]);

  // The slice we actually render. Lazy-load grows by PAGE each time.
  const renderedFiles = visibleFiles.slice(0, visibleCount);
  const hasMore = visibleCount < visibleFiles.length;

  // Reset page count when filter inputs change (otherwise switching
  // from "All" to "Images" leaves an arbitrary previous count).
  useEffect(() => { setVisibleCount(PAGE); }, [typeFilter, dateFilter, query, currentFolder]);

  // Auto-load more when sentinel scrolls into view (~ infinite scroll).
  useEffect(() => {
    if (!hasMore) return;
    const node = sentinelRef.current;
    if (!node) return;
    const obs = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) {
        setVisibleCount((c) => Math.min(visibleFiles.length, c + PAGE));
      }
    }, { rootMargin: '200px' });
    obs.observe(node);
    return () => obs.disconnect();
  }, [hasMore, visibleFiles.length]);

  return (
    <>
      <section
        ref={containerRef}
        className={`bg-[color:var(--surface)] border-0 md:border p-3 pt-4 md:p-5 md:rounded-2xl relative transition ${dragOver ? 'md:border-[color:var(--accent)] md:ring-2 md:ring-[color:var(--accent)]/30' : 'md:border-[color:var(--border)]'}`}
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

        {/* Storage card moved to /dashboard/devices on mobile — Files tab
            keeps focus on the file list (per user request). The desktop
            sidebar still shows live storage. */}

        {/* Breadcrumbs — Home / folder / sub-folder. Click any segment to jump. */}
        <Breadcrumbs path={path} onHome={() => navigateTo(null)} onJump={(id) => navigateTo(id)} />

        <div className="flex items-center justify-between mb-4">
          <div>
            <h2 className="text-[18px] md:text-[15px] font-semibold">{path.length === 0 ? 'My files' : path[path.length - 1].name}</h2>
            <p className="text-[12px] md:text-xs text-[color:var(--text-muted)] mt-0.5">
              {online ? `${visibleFiles.length} item${visibleFiles.length === 1 ? '' : 's'}` : 'Your storage is offline'}
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
            <select
              value={dateFilter}
              onChange={(e) => setDateFilter(e.target.value as DateRange)}
              className="h-9 px-3 text-[12px] bg-[color:var(--body)] rounded-lg border border-transparent focus:border-[color:var(--accent)] focus:outline-none cursor-pointer"
              aria-label="Date range"
              title="Date range"
            >
              <option value="all">Any date</option>
              <option value="today">Today</option>
              <option value="week">Past 7 days</option>
              <option value="month">Past 30 days</option>
              <option value="year">Past year</option>
            </select>
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
              onClick={() => setShowNewFolder(true)}
              disabled={!online}
              className="hidden sm:inline-flex items-center gap-1.5 bg-[color:var(--body)] hover:bg-[color:var(--accent-muted)] text-[color:var(--text)] text-xs font-semibold px-3 py-2 rounded-lg disabled:opacity-50"
              title="New folder"
            >
              <FolderPlus size={14} /> New folder
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

        {/* Filters: full-width search bar (YouTube-sized on mobile),
            then type chips. Date range + Refresh + New folder + Upload
            live in the toolbar above. Search input also feeds in from
            the top-bar global ?q= URL param so deep-linking works. */}
        <div className="mb-3 space-y-4 md:space-y-2">
          <div className="relative group">
            {/* Always-on accent glow so the search bar reads as the
                hero control. Intensifies on focus. */}
            <div className="md:hidden absolute -inset-0.5 rounded-full bg-gradient-to-r from-[color:var(--accent)]/40 to-[#B1A7F9]/40 blur-md group-focus-within:from-[color:var(--accent)]/70 group-focus-within:to-[#B1A7F9]/70 transition-all duration-300 pointer-events-none" />
            <Search size={18} className="md:hidden absolute left-4 top-1/2 -translate-y-1/2 text-[color:var(--accent)] z-10" strokeWidth={2.4} />
            <Search size={14} className="hidden md:block absolute left-3 top-1/2 -translate-y-1/2 text-[color:var(--text-muted)]" />
            <input
              value={localQuery || urlQuery}
              onChange={(e) => setLocalQuery(e.target.value)}
              placeholder="Search your files"
              className="relative w-full h-12 md:h-9 pl-11 md:pl-9 pr-12 md:pr-3 text-[15px] md:text-[13px] font-medium md:font-normal bg-[color:var(--surface)] md:bg-[color:var(--body)] rounded-full md:rounded-lg border-2 md:border border-[color:var(--accent)]/60 md:border-transparent focus:border-[color:var(--accent)] focus:outline-none focus:ring-4 focus:ring-[color:var(--accent)]/20 md:focus:ring-0 shadow-md md:shadow-none transition-all"
            />
            {(localQuery || urlQuery) && (
              <button
                onClick={() => setLocalQuery('')}
                className="md:hidden absolute right-2 top-1/2 -translate-y-1/2 z-10 p-1.5 rounded-full text-[color:var(--text-muted)] hover:bg-[color:var(--accent-muted)] hover:text-[color:var(--text)]"
                aria-label="Clear search"
              ><X size={16} /></button>
            )}
          </div>
          <div className="flex items-center gap-2 overflow-x-auto -mx-1 px-1 pb-1.5 scrollbar-thin">
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
                  className={`whitespace-nowrap inline-flex items-center gap-1.5 px-3.5 py-1.5 md:py-1 rounded-full text-[12px] md:text-[11.5px] font-medium transition-all duration-200 active:scale-95 ${
                    active
                      ? 'bg-[color:var(--accent)] text-white shadow-md shadow-[color:var(--accent)]/30 ring-1 ring-[color:var(--accent)]'
                      : 'bg-[color:var(--surface)] md:bg-[color:var(--body)] text-[color:var(--text-muted)] border border-[color:var(--border)] md:border-transparent hover:text-[color:var(--text)] hover:border-[color:var(--accent)]/30'
                  }`}
                ><I size={13} /> {c.label}</button>
              );
            })}
          </div>
        </div>

        {error && (
          <div className="mb-3 px-3 py-2 rounded-md bg-red-50 border border-red-200 text-red-700 text-xs">{error}</div>
        )}

        {!online ? <OfflineState /> : !reachable ? <UnreachableState /> : visibleFiles.length === 0 ? <EmptyState onPick={() => inputRef.current?.click()} /> : view === 'grid' ? (
          <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 gap-3">
            {renderedFiles.map((f) => (
              <FileGridCard
                key={f.id}
                file={f}
                isFav={favorites.has(f.id)}
                isFolder={isFolder(f)}
                isSelected={selected.has(f.id)}
                isMenuOpen={openMenu === f.id}
                onSelect={() => toggleSelect(f.id)}
                onMenuToggle={() => setOpenMenu(openMenu === f.id ? null : f.id)}
                onMenuClose={() => setOpenMenu(null)}
                onOpen={() => isFolder(f) ? enterFolder(f) : setPreviewTarget(f)}
                onDownload={() => downloadFile(f)}
                onDelete={() => setDeleteTarget(f)}
                onFavorite={() => toggleFavorite(f.id)}
                onRename={() => setRenameTarget(f)}
                onInfo={() => setInfoTarget(f)}
                onMove={() => setMovePicker({ ids: [f.id] })}
                onCopy={() => copyFile(f)}
              />
            ))}
          </div>
        ) : (
          <ul className="divide-y divide-[color:var(--border)]">
            {renderedFiles.map((f) => {
              const folder = isFolder(f);
              const isSel = selected.has(f.id);
              const isDropTarget = folder && dropTargetFolderId === f.id && dragRowId !== null;
              return (
                <li
                  key={f.id}
                  draggable
                  onDragStart={(e) => { setDragRowId(f.id); e.dataTransfer.effectAllowed = 'move'; }}
                  onDragEnd={() => { setDragRowId(null); setDropTargetFolderId(null); }}
                  onDragOver={folder ? (e) => { e.preventDefault(); e.stopPropagation(); if (dragRowId && dragRowId !== f.id) setDropTargetFolderId(f.id); } : undefined}
                  onDragLeave={folder ? () => setDropTargetFolderId(null) : undefined}
                  onDrop={folder ? (e) => {
                    e.preventDefault(); e.stopPropagation();
                    setDropTargetFolderId(null);
                    if (dragRowId && dragRowId !== f.id) {
                      // If the dragged row is part of a multi-selection, move
                      // them all; otherwise just the single row.
                      const ids = selected.has(dragRowId) ? Array.from(selected) : [dragRowId];
                      moveFiles(ids, f.id);
                    }
                    setDragRowId(null);
                  } : undefined}
                  className={`group flex items-center gap-3 py-3 md:py-3 px-2 rounded-xl transition-all duration-150 cursor-default active:scale-[0.985] active:bg-[color:var(--accent-muted)]/60 ${
                    isDropTarget ? 'bg-[color:var(--accent-muted)] ring-2 ring-[color:var(--accent)]'
                    : isSel ? 'bg-[color:var(--accent-muted)]'
                    : 'hover:bg-[color:var(--accent-muted)]/40'
                  }`}
                >
                  <input
                    type="checkbox"
                    checked={isSel}
                    onChange={() => toggleSelect(f.id)}
                    onClick={(e) => e.stopPropagation()}
                    className="w-4 h-4 accent-[color:var(--accent)] cursor-pointer"
                    aria-label={`Select ${f.name}`}
                  />
                  <button
                    onClick={() => folder ? enterFolder(f) : setPreviewTarget(f)}
                    className="flex-1 min-w-0 flex items-center gap-3 text-left"
                  >
                    {folder ? (
                      <div className="w-[54px] h-[54px] md:w-10 md:h-10 rounded-2xl md:rounded-lg flex items-center justify-center flex-shrink-0 shadow-sm" style={{ background: 'linear-gradient(135deg, #FDE68A 0%, #FCD34D 100%)' }}>
                        <FolderIcon size={26} className="text-amber-700 md:hidden drop-shadow-sm" fill="#FBBF24" />
                        <FolderIcon size={18} className="text-amber-700 hidden md:block" fill="#FBBF24" />
                      </div>
                    ) : (
                      <div className="md:hidden"><FilePreview mime={f.mime} name={f.name} size={54} /></div>
                    )}
                    {!folder && <div className="hidden md:block"><FilePreview mime={f.mime} name={f.name} /></div>}
                    <div className="flex-1 min-w-0">
                      <div className="text-[16.5px] md:text-[13px] font-medium truncate flex items-center gap-1.5">
                        <span className="truncate">{f.name}</span>
                        {favorites.has(f.id) && <Star size={13} className="text-amber-500 flex-shrink-0" fill="currentColor" />}
                      </div>
                      <div className="text-[13px] md:text-[11px] text-[color:var(--text-muted)] mt-0.5">
                        {folder ? `Folder · ${fmtDate(f.created_at)}` : `${formatBytes(f.size)} · ${fmtDate(f.created_at)}`}
                      </div>
                    </div>
                  </button>
                  {!folder && (
                    <>
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
                    </>
                  )}
                  <RowMenu
                    isOpen={openMenu === f.id}
                    onToggle={() => setOpenMenu(openMenu === f.id ? null : f.id)}
                    onClose={() => setOpenMenu(null)}
                    isFav={favorites.has(f.id)}
                    isFolder={folder}
                    onRename={() => setRenameTarget(f)}
                    onInfo={() => setInfoTarget(f)}
                    onFavorite={() => toggleFavorite(f.id)}
                    onDelete={() => setDeleteTarget(f)}
                    onMove={() => setMovePicker({ ids: [f.id] })}
                    onCopy={() => copyFile(f)}
                  />
                </li>
              );
            })}
          </ul>
        )}

        {/* Click-catcher behind the per-row ⋯ menu. Sits above rows
            (z-15) but below the menu itself (z-20) so an outside click
            CLOSES the menu without ALSO triggering the row's onClick
            (which would open the file preview). */}
        {openMenu && (
          <div
            className="fixed inset-0 z-[15]"
            onClick={() => setOpenMenu(null)}
            onContextMenu={() => setOpenMenu(null)}
            aria-hidden="true"
          />
        )}

        {/* Lazy-load sentinel — when this scrolls into view, the next
            12 files render. Shown only when there are more to load. */}
        {hasMore && (
          <div ref={sentinelRef} className="py-6 text-center text-[12px] text-[color:var(--text-muted)]">
            Loading more… ({visibleFiles.length - visibleCount} remaining)
          </div>
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
        {previewTarget && (
          <PreviewModal
            file={previewTarget}
            onClose={() => setPreviewTarget(null)}
            onDownload={() => downloadFile(previewTarget)}
          />
        )}
        {showNewFolder && (
          <NewFolderModal busy={busy} onCancel={() => setShowNewFolder(false)} onCreate={createFolder} />
        )}
        {movePicker && (
          <MoveToPicker
            ids={movePicker.ids}
            currentFolder={currentFolder}
            onCancel={() => setMovePicker(null)}
            onMove={(targetId) => moveFiles(movePicker.ids, targetId)}
          />
        )}

        {/* Bulk action bar — shown when at least one file is selected. */}
        {selected.size > 0 && (
          <BulkActionBar
            count={selected.size}
            allCount={files.length}
            onSelectAll={selectAll}
            onClear={clearSelection}
            onMove={() => setMovePicker({ ids: Array.from(selected) })}
            onDelete={() => bulkDelete(Array.from(selected))}
            onDownload={() => {
              // Trigger one download per selected file. Browser queues
              // them with the user's per-host concurrency limits.
              const targets = files.filter((f) => selected.has(f.id) && !isFolder(f));
              targets.forEach((f) => downloadFile(f));
            }}
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

      {/* Floating action button — lifted above MobileNav (z-50 vs nav's
          z-40) with a soft glow so it reads as the primary action. */}
      <button
        onClick={() => setShowFabMenu((s) => !s)}
        disabled={!online}
        className="sm:hidden fixed right-5 bottom-20 z-50 w-14 h-14 rounded-full text-white disabled:opacity-50 flex items-center justify-center transition-transform duration-200 active:scale-95"
        style={{
          background: 'linear-gradient(135deg, #8F93F6 0%, #6E74F2 100%)',
          boxShadow: '0 8px 24px -4px rgba(110, 116, 242, 0.5), 0 4px 8px -2px rgba(0, 0, 0, 0.1)',
          transform: showFabMenu ? 'rotate(45deg)' : 'none',
        }}
        aria-label={showFabMenu ? 'Close create menu' : 'Create new'}
      >
        <Plus size={26} strokeWidth={2.5} />
      </button>

      {/* FAB action sheet — Upload files / New folder. */}
      {showFabMenu && (
        <>
          <div className="sm:hidden fixed inset-0 z-40 bg-black/40 backdrop-blur-sm transition-opacity" onClick={() => setShowFabMenu(false)} />
          <div className="sm:hidden fixed right-5 bottom-40 z-50 flex flex-col gap-2.5 items-end" style={{ animation: 'fab-rise 0.18s ease-out' }}>
            <button
              onClick={() => { setShowFabMenu(false); inputRef.current?.click(); }}
              className="inline-flex items-center gap-2.5 bg-[color:var(--surface)] border border-[color:var(--border)] text-[color:var(--text)] text-[13px] font-semibold pl-3 pr-5 py-3 rounded-full shadow-xl active:scale-95 transition-transform"
            >
              <span className="w-8 h-8 rounded-full bg-[color:var(--accent-muted)] text-[color:var(--accent)] flex items-center justify-center"><Upload size={15} /></span>
              Upload files
            </button>
            <button
              onClick={() => { setShowFabMenu(false); setShowNewFolder(true); }}
              className="inline-flex items-center gap-2.5 bg-[color:var(--surface)] border border-[color:var(--border)] text-[color:var(--text)] text-[13px] font-semibold pl-3 pr-5 py-3 rounded-full shadow-xl active:scale-95 transition-transform"
            >
              <span className="w-8 h-8 rounded-full bg-amber-100 text-amber-600 flex items-center justify-center"><FolderPlus size={15} /></span>
              New folder
            </button>
          </div>
        </>
      )}
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
  file, isFav, isFolder: folder, isSelected, isMenuOpen,
  onSelect, onMenuToggle, onMenuClose, onOpen, onDownload, onDelete, onFavorite, onRename, onInfo, onMove, onCopy,
}: {
  file: FileItem;
  isFav: boolean;
  isFolder: boolean;
  isSelected: boolean;
  isMenuOpen: boolean;
  onSelect: () => void;
  onMenuToggle: () => void;
  onMenuClose: () => void;
  onOpen: () => void;
  onDownload: () => void;
  onDelete: () => void;
  onFavorite: () => void;
  onRename: () => void;
  onInfo: () => void;
  onMove: () => void;
  onCopy: () => void;
}) {
  return (
    <div
      className={`group relative flex flex-col rounded-xl border bg-[color:var(--surface)] overflow-hidden transition cursor-pointer ${isSelected ? 'border-[color:var(--accent)] ring-2 ring-[color:var(--accent)]/40' : 'border-[color:var(--border)] hover:shadow-md hover:border-[color:var(--accent)]'}`}
      onClick={onOpen}
      role="button"
      tabIndex={0}
      aria-label={folder ? `Open folder ${file.name}` : `Open ${file.name}`}
    >
      <div className="aspect-square flex items-center justify-center bg-[color:var(--body)]">
        {folder ? (
          <FolderIcon size={48} className="text-amber-500" fill="#FDE68A" />
        ) : (
          <div className="scale-150"><FilePreview mime={file.mime} name={file.name} /></div>
        )}
      </div>
      <div className="p-3">
        <div className="flex items-center gap-1.5 mb-0.5">
          <div className="flex-1 min-w-0 text-[12px] font-medium truncate">{file.name}</div>
          {isFav && <Star size={11} className="text-amber-500 flex-shrink-0" fill="currentColor" />}
        </div>
        <div className="text-[10px] text-[color:var(--text-muted)]">{folder ? 'Folder' : formatBytes(file.size)}</div>
      </div>
      <input
        type="checkbox"
        checked={isSelected}
        onChange={onSelect}
        onClick={(e) => e.stopPropagation()}
        className={`absolute top-2 left-2 w-4 h-4 accent-[color:var(--accent)] cursor-pointer ${isSelected ? '' : 'opacity-0 group-hover:opacity-100'} transition`}
        aria-label={`Select ${file.name}`}
      />
      <button
        onClick={(e) => { e.stopPropagation(); onMenuToggle(); }}
        className="absolute top-2 right-2 p-1.5 rounded-lg bg-[color:var(--surface)]/80 backdrop-blur text-[color:var(--text-muted)] hover:text-[color:var(--text)] opacity-0 group-hover:opacity-100 transition"
        aria-label="More"
      >
        <MoreVertical size={14} />
      </button>
      {isMenuOpen && (
        <div
          className="absolute top-10 right-2 z-20 w-48 rounded-lg bg-[color:var(--surface)] border border-[color:var(--border)] shadow-lg py-1 text-[12px]"
          onClick={(e) => e.stopPropagation()}
        >
          {!folder && (
            <button onClick={() => { onDownload(); onMenuClose(); }} className="w-full text-left px-3 py-1.5 hover:bg-[color:var(--accent-muted)] flex items-center gap-2"><Download size={12} /> Download</button>
          )}
          <button onClick={() => { onRename(); onMenuClose(); }} className="w-full text-left px-3 py-1.5 hover:bg-[color:var(--accent-muted)] flex items-center gap-2"><Pencil size={12} /> Rename</button>
          <button onClick={() => { onMove(); onMenuClose(); }} className="w-full text-left px-3 py-1.5 hover:bg-[color:var(--accent-muted)] flex items-center gap-2"><Move size={12} /> Move to…</button>
          {!folder && (
            <button onClick={() => { onCopy(); onMenuClose(); }} className="w-full text-left px-3 py-1.5 hover:bg-[color:var(--accent-muted)] flex items-center gap-2"><CopyIcon size={12} /> Make a copy</button>
          )}
          {!folder && (
            <button onClick={() => { onFavorite(); onMenuClose(); }} className="w-full text-left px-3 py-1.5 hover:bg-[color:var(--accent-muted)] flex items-center gap-2">
              <Star size={12} className={isFav ? 'text-amber-500' : ''} fill={isFav ? 'currentColor' : 'none'} />
              {isFav ? 'Remove from Starred' : 'Add to Starred'}
            </button>
          )}
          <button onClick={() => { onInfo(); onMenuClose(); }} className="w-full text-left px-3 py-1.5 hover:bg-[color:var(--accent-muted)] flex items-center gap-2"><Info size={12} /> File info</button>
          <div className="my-1 border-t border-[color:var(--border)]" />
          <button onClick={() => { onDelete(); onMenuClose(); }} className="w-full text-left px-3 py-1.5 hover:bg-red-50 hover:text-red-600 flex items-center gap-2"><Trash2 size={12} /> Delete</button>
        </div>
      )}
    </div>
  );
}

function RowMenu({
  isOpen, onToggle, onClose, isFav, isFolder: folder, onRename, onInfo, onFavorite, onDelete, onMove, onCopy,
}: {
  isOpen: boolean;
  onToggle: () => void;
  onClose: () => void;
  isFav: boolean;
  isFolder?: boolean;
  onRename: () => void;
  onInfo: () => void;
  onFavorite: () => void;
  onDelete: () => void;
  onMove: () => void;
  onCopy: () => void;
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
          className="absolute right-0 top-full mt-1 z-20 w-48 rounded-lg bg-[color:var(--surface)] border border-[color:var(--border)] shadow-lg py-1 text-[12px]"
          onClick={(e) => e.stopPropagation()}
        >
          <button onClick={() => { onRename(); onClose(); }} className="w-full text-left px-3 py-1.5 hover:bg-[color:var(--accent-muted)] flex items-center gap-2"><Pencil size={12} /> Rename</button>
          <button onClick={() => { onMove(); onClose(); }} className="w-full text-left px-3 py-1.5 hover:bg-[color:var(--accent-muted)] flex items-center gap-2"><Move size={12} /> Move to…</button>
          {!folder && (
            <button onClick={() => { onCopy(); onClose(); }} className="w-full text-left px-3 py-1.5 hover:bg-[color:var(--accent-muted)] flex items-center gap-2"><CopyIcon size={12} /> Make a copy</button>
          )}
          {!folder && (
            <button onClick={() => { onFavorite(); onClose(); }} className="w-full text-left px-3 py-1.5 hover:bg-[color:var(--accent-muted)] flex items-center gap-2">
              <Star size={12} className={isFav ? 'text-amber-500' : ''} fill={isFav ? 'currentColor' : 'none'} />
              {isFav ? 'Remove from Starred' : 'Add to Starred'}
            </button>
          )}
          <button onClick={() => { onInfo(); onClose(); }} className="w-full text-left px-3 py-1.5 hover:bg-[color:var(--accent-muted)] flex items-center gap-2"><Info size={12} /> File info</button>
          <div className="my-1 border-t border-[color:var(--border)]" />
          <button onClick={() => { onDelete(); onClose(); }} className="w-full text-left px-3 py-1.5 hover:bg-red-50 hover:text-red-600 flex items-center gap-2"><Trash2 size={12} /> Delete</button>
        </div>
      )}
    </div>
  );
}

function Breadcrumbs({ path, onHome, onJump }: { path: Crumb[]; onHome: () => void; onJump: (id: string) => void }) {
  if (path.length === 0) return null;
  return (
    <div className="mb-3 flex items-center gap-1 text-[13px] overflow-x-auto whitespace-nowrap pb-1">
      <button onClick={onHome} className="inline-flex items-center gap-1 px-2 py-1 rounded-md hover:bg-[color:var(--accent-muted)] text-[color:var(--text-muted)] hover:text-[color:var(--accent)]">
        <Home size={13} /> My files
      </button>
      {path.map((c, i) => (
        <span key={c.id} className="inline-flex items-center gap-1">
          <ChevronRight size={12} className="text-[color:var(--text-muted)]" />
          {i === path.length - 1 ? (
            <span className="px-2 py-1 font-semibold text-[color:var(--text)]">{c.name}</span>
          ) : (
            <button onClick={() => onJump(c.id)} className="px-2 py-1 rounded-md hover:bg-[color:var(--accent-muted)] text-[color:var(--text-muted)] hover:text-[color:var(--accent)]">{c.name}</button>
          )}
        </span>
      ))}
    </div>
  );
}

function BulkActionBar({
  count, allCount, onSelectAll, onClear, onMove, onDelete, onDownload,
}: {
  count: number;
  allCount: number;
  onSelectAll: () => void;
  onClear: () => void;
  onMove: () => void;
  onDelete: () => void;
  onDownload: () => void;
}) {
  // Lifted above MobileNav (~64 px) on mobile so it doesn't disappear
  // behind the bottom tabs. z-50 to clear MobileNav (z-40).
  return (
    <div className="fixed bottom-20 md:bottom-4 left-1/2 -translate-x-1/2 z-50 bg-[color:var(--surface)] border border-[color:var(--border)] rounded-full shadow-xl px-4 py-2 flex items-center gap-2 max-w-[95vw]">
      <button onClick={onClear} className="p-1.5 rounded-full text-[color:var(--text-muted)] hover:bg-[color:var(--accent-muted)] hover:text-[color:var(--text)]" aria-label="Clear selection">
        <X size={14} />
      </button>
      <span className="text-[12px] font-medium text-[color:var(--text)] mr-1 whitespace-nowrap">{count} selected</span>
      {count < allCount && (
        <button onClick={onSelectAll} className="hidden sm:inline text-[11px] text-[color:var(--accent)] font-medium hover:underline mr-1 whitespace-nowrap">
          Select all ({allCount})
        </button>
      )}
      <div className="w-px h-5 bg-[color:var(--border)] mx-1" />
      <button onClick={onDownload} className="inline-flex items-center gap-1 px-3 py-1.5 text-[12px] font-medium rounded-full hover:bg-[color:var(--accent-muted)] text-[color:var(--text)]" title="Download selected">
        <Download size={13} /> <span className="hidden sm:inline">Download</span>
      </button>
      <button onClick={onMove} className="inline-flex items-center gap-1 px-3 py-1.5 text-[12px] font-medium rounded-full hover:bg-[color:var(--accent-muted)] text-[color:var(--text)]" title="Move selected">
        <Move size={13} /> <span className="hidden sm:inline">Move</span>
      </button>
      <button onClick={onDelete} className="inline-flex items-center gap-1 px-3 py-1.5 text-[12px] font-medium rounded-full hover:bg-red-50 text-red-600" title="Delete selected">
        <Trash2 size={13} /> <span className="hidden sm:inline">Delete</span>
      </button>
    </div>
  );
}

function NewFolderModal({ busy, onCancel, onCreate }: { busy: boolean; onCancel: () => void; onCreate: (name: string) => void }) {
  const [name, setName] = useState('Untitled folder');
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={onCancel} role="dialog" aria-modal="true">
      <div className="w-full max-w-sm rounded-2xl bg-[color:var(--surface)] border border-[color:var(--border)] p-5 shadow-xl" onClick={(e) => e.stopPropagation()}>
        <h3 className="text-[15px] font-semibold mb-3 flex items-center gap-2"><FolderPlus size={16} /> New folder</h3>
        <input
          autoFocus
          value={name}
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter' && !busy) onCreate(name); }}
          onFocus={(e) => e.target.select()}
          className="w-full h-10 px-3 text-[13px] bg-[color:var(--body)] rounded-lg border border-transparent focus:border-[color:var(--accent)] focus:outline-none mb-4"
        />
        <div className="flex justify-end gap-2">
          <button onClick={onCancel} disabled={busy} className="px-4 py-2 text-[12px] text-[color:var(--text-muted)] hover:text-[color:var(--text)]">Cancel</button>
          <button onClick={() => onCreate(name)} disabled={busy || !name.trim()} className="px-4 py-2 text-[12px] font-semibold bg-[color:var(--accent)] hover:bg-[color:var(--accent-hover)] disabled:opacity-50 text-white rounded-lg">Create</button>
        </div>
      </div>
    </div>
  );
}

function MoveToPicker({
  ids, currentFolder, onCancel, onMove,
}: {
  ids: string[];
  currentFolder: string | null;
  onCancel: () => void;
  onMove: (targetParentId: string | null) => void;
}) {
  // Browse the folder tree. Picker fetches children on demand. Disables
  // any folder that's in `ids` (can't move a folder into itself).
  const [browseId, setBrowseId] = useState<string | null>(null);
  const [browsePath, setBrowsePath] = useState<Crumb[]>([]);
  const [items, setItems] = useState<FileItem[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let alive = true;
    (async () => {
      setLoading(true);
      try {
        const qs = browseId ? `?parent=${encodeURIComponent(browseId)}` : '';
        const r = await fetch(`/api/files${qs}`, { cache: 'no-store' });
        const body = await r.json();
        if (!alive) return;
        setItems((body.files ?? []).filter((x: FileItem) => isFolder(x)));
        setBrowsePath(body.path ?? []);
      } catch { /* ignore */ }
      finally { if (alive) setLoading(false); }
    })();
    return () => { alive = false; };
  }, [browseId]);

  const idsSet = new Set(ids);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={onCancel} role="dialog" aria-modal="true">
      <div className="w-full max-w-md rounded-2xl bg-[color:var(--surface)] border border-[color:var(--border)] p-5 shadow-xl flex flex-col max-h-[80vh]" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between mb-3">
          <h3 className="text-[15px] font-semibold flex items-center gap-2"><Move size={16} /> Move {ids.length} item{ids.length === 1 ? '' : 's'} to…</h3>
          <button onClick={onCancel} className="text-[color:var(--text-muted)] hover:text-[color:var(--text)] p-1" aria-label="Close"><X size={16} /></button>
        </div>
        <Breadcrumbs path={browsePath} onHome={() => setBrowseId(null)} onJump={(id) => setBrowseId(id)} />
        <div className="flex-1 min-h-0 overflow-auto rounded-lg border border-[color:var(--border)] bg-[color:var(--body)] p-1 mb-3">
          {loading ? (
            <div className="text-center py-8 text-[12px] text-[color:var(--text-muted)]">Loading…</div>
          ) : items.length === 0 ? (
            <div className="text-center py-8 text-[12px] text-[color:var(--text-muted)]">No subfolders here. You can still move into this folder.</div>
          ) : (
            <ul>
              {items.map((f) => {
                const disabled = idsSet.has(f.id);
                return (
                  <li key={f.id}>
                    <button
                      onClick={() => !disabled && setBrowseId(f.id)}
                      disabled={disabled}
                      className={`w-full text-left flex items-center gap-2 px-2 py-2 rounded-md text-[12.5px] ${disabled ? 'opacity-40 cursor-not-allowed' : 'hover:bg-[color:var(--accent-muted)]'}`}
                    >
                      <FolderIcon size={14} className="text-amber-600" fill="#FDE68A" />
                      <span className="flex-1 truncate">{f.name}</span>
                      {!disabled && <ChevronRight size={12} className="text-[color:var(--text-muted)]" />}
                    </button>
                  </li>
                );
              })}
            </ul>
          )}
        </div>
        <div className="flex justify-between items-center gap-2">
          <button onClick={onCancel} className="px-3 py-2 text-[12px] text-[color:var(--text-muted)] hover:text-[color:var(--text)]">Cancel</button>
          <button
            onClick={() => onMove(browseId)}
            disabled={browseId === currentFolder}
            className="px-4 py-2 text-[12px] font-semibold bg-[color:var(--accent)] hover:bg-[color:var(--accent-hover)] disabled:opacity-50 text-white rounded-lg"
          >
            Move here
          </button>
        </div>
      </div>
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

function PreviewModal({ file, onClose, onDownload }: { file: FileItem; onClose: () => void; onDownload: () => void }) {
  const url = `/api/files/${encodeURIComponent(file.id)}`;
  const ext = (file.name.split('.').pop() ?? '').toLowerCase();
  const isImage = file.mime.startsWith('image/');
  const isVideo = file.mime.startsWith('video/');
  const isAudio = file.mime.startsWith('audio/');
  const isPdf = file.mime === 'application/pdf';
  const isCsv = ext === 'csv' || file.mime === 'text/csv';
  const isText = !isCsv && (file.mime.startsWith('text/') || ['md','json','yaml','yml','log','txt'].includes(ext));

  // Universal "loaded?" state. Set true when the underlying element
  // fires onLoad / onCanPlay (or the fetch completes for text/CSV).
  // Spinner overlay shows until this flips, so the modal never feels
  // frozen — even on a slow phone with a big image.
  const [loaded, setLoaded] = useState(isImage || isVideo || isAudio || isPdf ? false : true);
  const [text, setText] = useState<string | null>(null);
  const [textErr, setTextErr] = useState<string | null>(null);

  useEffect(() => {
    if (!(isText || isCsv)) return;
    let alive = true;
    (async () => {
      try {
        const r = await fetch(url);
        if (!r.ok) throw new Error(`${r.status}`);
        const t = await r.text();
        if (alive) { setText(t); setLoaded(true); }
      } catch (e) {
        if (alive) { setTextErr(String(e)); setLoaded(true); }
      }
    })();
    return () => { alive = false; };
  }, [isText, isCsv, url]);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-2 sm:p-6" onClick={onClose} role="dialog" aria-modal="true">
      <div className="w-full max-w-5xl h-full max-h-[92vh] rounded-xl bg-[color:var(--surface)] border border-[color:var(--border)] shadow-2xl flex flex-col overflow-hidden" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between px-4 py-3 border-b border-[color:var(--border)]">
          <div className="flex items-center gap-3 min-w-0">
            <FilePreview mime={file.mime} name={file.name} />
            <div className="min-w-0">
              <div className="text-[14px] font-semibold truncate">{file.name}</div>
              <div className="text-[11px] text-[color:var(--text-muted)]">{formatBytes(file.size)} · {fmtFullDate(file.created_at)}</div>
            </div>
          </div>
          <div className="flex items-center gap-1">
            <button onClick={onDownload} className="inline-flex items-center gap-1.5 bg-[color:var(--accent)] hover:bg-[color:var(--accent-hover)] text-white text-[12px] font-semibold px-3 py-2 rounded-lg">
              <Download size={14} /> <span className="hidden sm:inline">Download</span>
            </button>
            <button onClick={onClose} className="text-[color:var(--text-muted)] hover:text-[color:var(--text)] p-2" aria-label="Close"><X size={18} /></button>
          </div>
        </div>
        <div className="flex-1 min-h-0 bg-[color:var(--body)] relative flex items-center justify-center overflow-auto">
          {/* Loader overlay — visible until `loaded` flips true. */}
          {!loaded && !textErr && <PreviewSpinner />}
          {textErr && (
            <div className="text-[12px] text-red-600 py-12 px-4 text-center">Could not load: {textErr}</div>
          )}

          {isImage && (
            <img
              src={url}
              alt={file.name}
              onLoad={() => setLoaded(true)}
              onError={() => { setLoaded(true); setTextErr('image failed'); }}
              className={`max-w-full max-h-full object-contain transition-opacity duration-300 ${loaded ? 'opacity-100' : 'opacity-0'}`}
            />
          )}
          {isVideo && (
            <video
              src={url}
              controls
              onLoadedData={() => setLoaded(true)}
              onError={() => { setLoaded(true); setTextErr('video failed'); }}
              className={`max-w-full max-h-full transition-opacity duration-300 ${loaded ? 'opacity-100' : 'opacity-0'}`}
            />
          )}
          {isAudio && (
            <div className={`p-6 w-full max-w-md transition-opacity duration-300 ${loaded ? 'opacity-100' : 'opacity-0'}`}>
              <audio
                src={url}
                controls
                onLoadedData={() => setLoaded(true)}
                onError={() => { setLoaded(true); setTextErr('audio failed'); }}
                className="w-full"
              />
            </div>
          )}
          {isPdf && (
            <iframe
              src={url}
              onLoad={() => setLoaded(true)}
              title={file.name}
              className={`w-full h-full bg-white transition-opacity duration-300 ${loaded ? 'opacity-100' : 'opacity-0'}`}
            />
          )}
          {isCsv && text != null && <CsvTable raw={text} />}
          {isText && text != null && (
            <pre className="w-full h-full p-4 text-[12px] font-mono whitespace-pre-wrap overflow-auto text-[color:var(--text)]">{text}</pre>
          )}
          {!isImage && !isVideo && !isAudio && !isPdf && !isText && !isCsv && (
            <div className="text-center p-8">
              <File size={48} className="mx-auto mb-3 text-[color:var(--text-muted)]" />
              <div className="text-[13px] font-semibold mb-1">No preview available</div>
              <div className="text-[11px] text-[color:var(--text-muted)] mb-4">This file type can&rsquo;t be previewed in the browser.</div>
              <button onClick={onDownload} className="inline-flex items-center gap-1.5 bg-[color:var(--accent)] hover:bg-[color:var(--accent-hover)] text-white text-[12px] font-semibold px-4 py-2 rounded-lg">
                <Download size={14} /> Download
              </button>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

function PreviewSpinner() {
  return (
    <div className="absolute inset-0 flex flex-col items-center justify-center pointer-events-none gap-3 z-10">
      <div className="w-10 h-10 rounded-full border-2 border-[color:var(--border)] border-t-[color:var(--accent)] animate-spin" />
      <div className="text-[11px] text-[color:var(--text-muted)] font-medium">Loading preview…</div>
    </div>
  );
}

// Tiny CSV parser — handles quoted fields with embedded commas + double-quote
// escapes ("foo,""bar"""). Big enough for spreadsheets exported by Excel/Sheets;
// not aiming for full RFC 4180 compliance.
function parseCsv(raw: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = '';
  let inQuotes = false;
  for (let i = 0; i < raw.length; i++) {
    const ch = raw[i];
    if (inQuotes) {
      if (ch === '"') {
        if (raw[i + 1] === '"') { field += '"'; i++; } else { inQuotes = false; }
      } else {
        field += ch;
      }
    } else if (ch === '"') {
      inQuotes = true;
    } else if (ch === ',') {
      row.push(field); field = '';
    } else if (ch === '\n' || ch === '\r') {
      // Treat \r\n as a single newline
      if (ch === '\r' && raw[i + 1] === '\n') i++;
      row.push(field); field = '';
      rows.push(row); row = [];
    } else {
      field += ch;
    }
  }
  if (field.length > 0 || row.length > 0) { row.push(field); rows.push(row); }
  return rows.filter((r) => r.length > 1 || (r.length === 1 && r[0] !== ''));
}

function CsvTable({ raw }: { raw: string }) {
  const rows = useMemo(() => parseCsv(raw).slice(0, 1000), [raw]);
  if (rows.length === 0) {
    return <div className="text-[12px] text-[color:var(--text-muted)] py-12">Empty CSV</div>;
  }
  const [header, ...body] = rows;
  return (
    <div className="w-full h-full overflow-auto p-3">
      <table className="min-w-full text-[12px] border-collapse">
        <thead className="sticky top-0 bg-[color:var(--surface)] z-10">
          <tr>
            {header.map((cell, i) => (
              <th key={i} className="px-3 py-2 text-left font-semibold border-b border-[color:var(--border)] whitespace-nowrap">{cell}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {body.map((row, ri) => (
            <tr key={ri} className={ri % 2 === 0 ? 'bg-[color:var(--body)]' : 'bg-[color:var(--surface)]'}>
              {header.map((_, ci) => (
                <td key={ci} className="px-3 py-1.5 border-b border-[color:var(--border)] whitespace-nowrap text-[color:var(--text)]">{row[ci] ?? ''}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
      {parseCsv(raw).length > 1000 && (
        <div className="text-center text-[10px] text-[color:var(--text-muted)] py-3">First 1,000 rows shown — download the file to see the rest.</div>
      )}
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
function FilePreview({ mime, name, size = 36 }: { mime: string; name: string; size?: number }) {
  const ext = name.split('.').pop()?.toLowerCase() ?? '';
  const kind = mimeKind(mime, ext);
  const iconSize = Math.round(size * 0.45);

  const styles: Record<string, { bg: string; fg: string; label?: string; icon: React.ReactNode }> = {
    image: {
      bg: 'linear-gradient(135deg, #C4B5FD 0%, #8B5CF6 100%)',
      fg: '#fff',
      icon: <ImageIcon size={iconSize} />,
    },
    pdf: { bg: '#FEE2E2', fg: '#DC2626', label: 'PDF', icon: <FileText size={iconSize} /> },
    audio: { bg: 'linear-gradient(135deg, #FBCFE8 0%, #EC4899 100%)', fg: '#fff', icon: <Music size={iconSize} /> },
    video: { bg: 'linear-gradient(135deg, #1F2937 0%, #4B5563 100%)', fg: '#fff', icon: <Film size={iconSize} /> },
    spreadsheet: { bg: '#D1FAE5', fg: '#059669', label: ext.toUpperCase().slice(0, 4), icon: <FileSpreadsheet size={iconSize} /> },
    archive: { bg: '#FEF3C7', fg: '#D97706', label: ext.toUpperCase().slice(0, 4), icon: <Archive size={iconSize} /> },
    code: { bg: '#DBEAFE', fg: '#2563EB', label: ext.toUpperCase().slice(0, 4), icon: <FileCode size={iconSize} /> },
    text: { bg: '#DBEAFE', fg: '#2563EB', icon: <FileText size={iconSize} /> },
    other: { bg: '#E5E7EB', fg: '#6B7280', icon: <File size={iconSize} /> },
  };

  const s = styles[kind] ?? styles.other;
  return (
    <div
      className="relative rounded-lg overflow-hidden flex items-center justify-center flex-shrink-0"
      style={{ width: size, height: size, background: s.bg, color: s.fg }}
    >
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
