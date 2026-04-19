import Link from 'next/link';
import { redirect } from 'next/navigation';
import { ArrowRight, FolderOpen, HardDrive } from 'lucide-react';
import { api } from '@/lib/api';
import { getSessionToken } from '@/lib/session';
import { StorageDonut } from './storage-donut';

export default async function DashboardPage() {
  const token = await getSessionToken();
  if (!token) redirect('/login');

  const [status, activeHost, filesRes, statsRes] = await Promise.all([
    api.billingStatus(token),
    api.activeHost(token),
    api.relayFiles(token),
    api.relayStats(token),
  ]);

  const initialFiles = filesRes?.files ?? [];
  const recent = [...initialFiles]
    .filter((f) => f.mime !== 'inode/directory')
    .sort((a, b) => b.created_at - a.created_at)
    .slice(0, 8);

  const inTrial = status.plan === 'trial' && status.trial_days_remaining > 0;

  return (
    <div className="px-3 md:px-6 py-3 md:py-6 space-y-4 md:space-y-6">
      <WelcomeHero plan={status.plan} trialDaysRemaining={status.trial_days_remaining} hasHost={!!activeHost} inTrial={inTrial} />

      <div className="grid grid-cols-1 lg:grid-cols-11 gap-4">
        <div className="lg:col-span-5">
          <StorageDonut
            usedBytes={statsRes?.used_bytes ?? 0}
            allocatedBytes={statsRes?.allocated_bytes ?? 0}
            fileCount={statsRes?.file_count ?? initialFiles.length}
            plan={status.plan}
          />
        </div>
        <div className="lg:col-span-6">
          <RecentFiles files={recent} totalCount={initialFiles.length} />
        </div>
      </div>
    </div>
  );
}

function WelcomeHero({ plan, trialDaysRemaining, hasHost, inTrial }: { plan: string; trialDaysRemaining: number; hasHost: boolean; inTrial: boolean }) {
  let msg: string;
  if (!hasHost) {
    msg = "You haven't set up your storage yet. Install the Weeber app on your computer — it becomes your cloud.";
  } else if (inTrial) {
    msg = `Your storage is online. You have ${trialDaysRemaining} day${trialDaysRemaining === 1 ? '' : 's'} left in your free trial.`;
  } else {
    msg = 'Your storage is online. Upload files here or from the app.';
  }
  return (
    <div className="rounded-2xl bg-[color:var(--surface)] border border-[color:var(--border)] p-6 flex gap-4 items-center shadow-sm">
      <div className="flex-1">
        <h1 className="text-2xl md:text-[28px] font-bold tracking-tight mb-2">Welcome back</h1>
        <p className="text-[12.5px] md:text-[13px] text-[color:var(--text-muted)] leading-relaxed">{msg}</p>
      </div>
      <div className="w-[140px] h-[100px] relative hidden sm:block">
        <div className="absolute w-9 h-7 rounded-md bg-[#FBBFC3]" style={{ left: 10, top: 60 }} />
        <div className="absolute w-8 h-10 rounded-md bg-[#C7CAFB]" style={{ left: 48, top: 50 }} />
        <div className="absolute w-10 h-12 rounded-md bg-[#FBD38D]" style={{ left: 82, top: 40 }} />
        <div className="absolute w-7 h-8 rounded-md bg-[#9AE6B4]" style={{ left: 52, top: 18 }} />
      </div>
    </div>
  );
}

function RecentFiles({ files, totalCount }: { files: Array<{ id: string; name: string; size: number; mime: string; created_at: number }>; totalCount: number }) {
  return (
    <div className="rounded-2xl bg-[color:var(--surface)] border border-[color:var(--border)] p-5 shadow-sm h-full">
      <div className="flex items-center justify-between mb-4">
        <div>
          <h3 className="text-[15px] font-semibold tracking-tight">Recent files</h3>
          <p className="text-[11px] text-[color:var(--text-muted)] mt-0.5">{totalCount} file{totalCount === 1 ? '' : 's'} total</p>
        </div>
        <Link href="/dashboard/files" className="inline-flex items-center gap-1 text-[12px] font-semibold text-[color:var(--accent)] hover:underline">
          See all <ArrowRight size={12} />
        </Link>
      </div>
      {files.length === 0 ? (
        <div className="text-center py-12">
          <div className="inline-flex items-center justify-center w-14 h-14 rounded-2xl bg-[color:var(--accent-muted)] text-[color:var(--accent)] mb-3">
            <FolderOpen size={22} />
          </div>
          <p className="text-[12px] text-[color:var(--text-muted)]">No files yet. <Link href="/dashboard/files" className="text-[color:var(--accent)] underline font-medium">Upload one →</Link></p>
        </div>
      ) : (
        <ul className="space-y-1">
          {files.map((f) => (
            <li key={f.id}>
              <Link
                href={`/dashboard/files?preview=${encodeURIComponent(f.id)}`}
                className="flex items-center gap-3 py-2 px-2 -mx-2 rounded-lg hover:bg-[color:var(--accent-muted)]/50 transition active:scale-[0.99]"
              >
                <RecentFileTile mime={f.mime} name={f.name} />
                <div className="flex-1 min-w-0">
                  <div className="text-[13px] font-medium truncate">{f.name}</div>
                  <div className="text-[10.5px] text-[color:var(--text-muted)]">{formatBytes(f.size)} · {fmtDate(f.created_at)}</div>
                </div>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

// Compact mime-typed tile for the recent-files list. Inline (no shared
// import) so the homepage stays a server component without 'use client'.
function RecentFileTile({ mime, name }: { mime: string; name: string }) {
  const ext = (name.split('.').pop() ?? '').toLowerCase();
  const kind =
    mime.startsWith('image/') ? 'image'
    : mime === 'application/pdf' ? 'pdf'
    : mime.startsWith('audio/') ? 'audio'
    : mime.startsWith('video/') ? 'video'
    : ['xls','xlsx','csv'].includes(ext) ? 'sheet'
    : ['zip','rar','7z','tar','gz'].includes(ext) ? 'zip'
    : mime.startsWith('text/') ? 'text'
    : 'other';
  const palette: Record<string, { bg: string; fg: string; label?: string }> = {
    image: { bg: 'linear-gradient(135deg, #C4B5FD 0%, #8B5CF6 100%)', fg: '#fff' },
    pdf: { bg: '#FEE2E2', fg: '#DC2626', label: 'PDF' },
    audio: { bg: 'linear-gradient(135deg, #FBCFE8 0%, #EC4899 100%)', fg: '#fff' },
    video: { bg: 'linear-gradient(135deg, #1F2937 0%, #4B5563 100%)', fg: '#fff' },
    sheet: { bg: '#D1FAE5', fg: '#059669', label: ext.toUpperCase().slice(0, 4) },
    zip: { bg: '#FEF3C7', fg: '#D97706', label: 'ZIP' },
    text: { bg: '#DBEAFE', fg: '#2563EB' },
    other: { bg: '#E5E7EB', fg: '#6B7280' },
  };
  const s = palette[kind];
  return (
    <div className="relative w-9 h-9 rounded-lg overflow-hidden flex items-center justify-center flex-shrink-0" style={{ background: s.bg, color: s.fg }}>
      <HardDrive size={14} />
      {s.label && (
        <div className="absolute bottom-0 left-0 right-0 text-[7px] font-bold tracking-wider text-center py-px" style={{ background: s.fg, color: '#fff' }}>{s.label}</div>
      )}
    </div>
  );
}

function fmtDate(unix: number) {
  return new Date(unix * 1000).toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
}

function formatBytes(b: number) {
  if (b < 1024) return `${b} B`;
  const u = ['KB', 'MB', 'GB', 'TB'];
  let v = b / 1024, i = 0;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(v >= 100 ? 0 : 1)} ${u[i]}`;
}
