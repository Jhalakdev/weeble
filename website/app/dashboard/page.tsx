import Link from 'next/link';
import { redirect } from 'next/navigation';
import { Link as LinkIcon, Laptop, Cloud, FolderOpen, ArrowRight } from 'lucide-react';
import { api } from '@/lib/api';
import { getSessionToken } from '@/lib/session';
import { LiveStorageCard } from '@/components/LiveStorageCard';
import { DeviceIcon } from './client-bits';

export default async function DashboardPage() {
  const token = await getSessionToken();
  if (!token) redirect('/login');

  const [status, devicesRes, sharesRes, activeHost, filesRes] = await Promise.all([
    api.billingStatus(token),
    api.listDevices(token).catch(() => ({ devices: [] })),
    api.listShares(token).catch(() => ({ shares: [] })),
    api.activeHost(token),
    api.relayFiles(token),
  ]);

  const devices = devicesRes.devices;
  const shares = sharesRes.shares;
  const hosts = devices.filter((d) => d.kind === 'host');
  const clients = devices.filter((d) => d.kind === 'client');
  const initialFiles = filesRes?.files ?? [];

  // Dashboard = at-a-glance only. The full file list lives at /dashboard/files
  // so the two screens have distinct purposes (was: dashboard + files
  // page rendered the same FilesPanel).
  const recent = [...initialFiles].sort((a, b) => b.created_at - a.created_at).slice(0, 6);

  return (
    <div className="px-3 md:px-6 py-3 md:py-6 space-y-3 md:space-y-6">
      <WelcomeHero
        plan={status.plan}
        trialDaysRemaining={status.trial_days_remaining}
        hasHost={!!activeHost}
      />

      <div className="grid grid-cols-1 lg:grid-cols-11 gap-4">
        <AtAGlance
          className="lg:col-span-4"
          hosts={hosts.length}
          clients={clients.length}
          files={initialFiles.length}
          shares={shares.length}
        />
        <DevicesPreview className="lg:col-span-7" devices={devices} activeHost={activeHost} />
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-11 gap-4">
        <div className="lg:col-span-7">
          <RecentFiles files={recent} totalCount={initialFiles.length} />
        </div>
        <div className="lg:col-span-4">
          <LiveStorageCard variant="block" />
        </div>
      </div>

      {shares.length > 0 && (
        <section>
          <h2 className="text-[15px] font-semibold mb-3">Recent shares</h2>
          <SharesTable shares={shares.slice(0, 5)} />
        </section>
      )}

      <div className="grid grid-cols-1 lg:grid-cols-11 gap-4 pb-8">
        <PlanCard
          className="lg:col-span-4"
          plan={status.plan}
          trialDaysRemaining={status.trial_days_remaining}
        />
        <UpgradeBanner className="lg:col-span-7" />
      </div>
    </div>
  );
}

function RecentFiles({ files, totalCount }: { files: Array<{ id: string; name: string; size: number; mime: string; created_at: number }>; totalCount: number }) {
  return (
    <div className="rounded-2xl bg-[color:var(--surface)] border border-[color:var(--border)] p-5">
      <div className="flex items-center justify-between mb-3">
        <div>
          <h3 className="text-sm font-semibold">Recent files</h3>
          <p className="text-xs text-[color:var(--text-muted)] mt-0.5">{totalCount} file{totalCount === 1 ? '' : 's'} total</p>
        </div>
        <Link href="/dashboard/files" className="inline-flex items-center gap-1 text-xs font-medium text-[color:var(--accent)] hover:underline">
          See all <ArrowRight size={12} />
        </Link>
      </div>
      {files.length === 0 ? (
        <div className="text-center py-8">
          <div className="inline-flex items-center justify-center w-12 h-12 rounded-2xl bg-[color:var(--accent-muted)] text-[color:var(--accent)] mb-2">
            <FolderOpen size={20} />
          </div>
          <p className="text-xs text-[color:var(--text-muted)]">No files yet. <Link href="/dashboard/files" className="text-[color:var(--accent)] underline">Upload one →</Link></p>
        </div>
      ) : (
        <ul className="divide-y divide-[color:var(--border)]">
          {files.map((f) => (
            <li key={f.id} className="flex items-center gap-3 py-2.5">
              <div className="w-8 h-8 rounded-lg bg-[color:var(--accent-muted)] text-[color:var(--accent)] flex items-center justify-center">
                <FolderOpen size={14} />
              </div>
              <div className="flex-1 min-w-0">
                <div className="text-[13px] font-medium truncate">{f.name}</div>
                <div className="text-[11px] text-[color:var(--text-muted)]">{formatBytes(f.size)} · {fmtDate(f.created_at)}</div>
              </div>
            </li>
          ))}
        </ul>
      )}
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

function WelcomeHero({ plan, trialDaysRemaining, hasHost }: { plan: string; trialDaysRemaining: number; hasHost: boolean }) {
  // Trial copy only when actually in trial AND days remaining > 0.
  // Paid plans (monthly / yearly / lifetime / etc.) and expired trials
  // both fall through to the generic message.
  const inTrial = plan === 'trial' && trialDaysRemaining > 0;
  let msg: string;
  if (!hasHost) {
    msg = "You haven't set up your storage yet. Install the Weeber app on your computer — it becomes your cloud.";
  } else if (inTrial) {
    msg = `Your storage is online. You have ${trialDaysRemaining} day${trialDaysRemaining === 1 ? '' : 's'} left in your free trial.`;
  } else {
    msg = 'Your storage is online. Upload files here or from the app.';
  }
  return (
    <div className="rounded-2xl bg-[color:var(--surface)] border border-[color:var(--border)] p-6 flex gap-4 items-center">
      <div className="flex-1">
        <h1 className="text-xl font-bold mb-2">Welcome back</h1>
        <p className="text-xs text-[color:var(--text-muted)] leading-relaxed">{msg}</p>
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

function AtAGlance({ className = '', hosts, clients, files, shares }: { className?: string; hosts: number; clients: number; files: number; shares: number }) {
  return (
    <div className={`rounded-2xl bg-[color:var(--surface)] border border-[color:var(--border)] p-5 ${className}`}>
      <h3 className="text-sm font-semibold mb-4">At a glance</h3>
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
        <Stat label="Files" value={files} color="#8F93F6" />
        <Stat label="Hosts" value={hosts} color="#6E74F2" />
        <Stat label="Clients" value={clients} color="#10B981" />
        <Stat label="Shares" value={shares} color="#F59E0B" />
      </div>
    </div>
  );
}

function Stat({ label, value, color }: { label: string; value: number; color: string }) {
  return (
    <div>
      <div className="w-2 h-2 rounded-full mb-2" style={{ background: color }} />
      <div className="text-2xl font-bold">{value}</div>
      <div className="text-[11px] text-[color:var(--text-muted)]">{label}</div>
    </div>
  );
}

function DevicesPreview({ className = '', devices, activeHost }: { className?: string; devices: Array<{ id: string; name: string; kind: string; platform: string; last_seen_at: number }>; activeHost: { device_id: string } | null }) {
  if (devices.length === 0) {
    return (
      <div className={`rounded-2xl bg-[color:var(--surface)] border border-[color:var(--border)] p-6 text-center ${className}`}>
        <div className="inline-flex items-center justify-center w-14 h-14 rounded-2xl bg-[color:var(--accent-muted)] text-[color:var(--accent)] mb-3">
          <Laptop size={24} />
        </div>
        <div className="text-sm font-semibold">No devices yet</div>
        <div className="text-xs text-[color:var(--text-muted)] mt-1 mb-4">Install Weeber on your computer to turn it into your cloud.</div>
        <Link href="/download" className="inline-block bg-[color:var(--accent)] text-white text-xs font-semibold px-4 py-2 rounded-md hover:bg-[color:var(--accent-hover)]">Download the app</Link>
      </div>
    );
  }
  return (
    <div className={`rounded-2xl bg-[color:var(--surface)] border border-[color:var(--border)] p-5 ${className}`}>
      <h3 className="text-sm font-semibold mb-3">Your devices</h3>
      <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
        {devices.slice(0, 6).map((d) => (
          <div key={d.id} className="flex items-center gap-3 p-3 rounded-xl border border-[color:var(--border)]">
            <DeviceIcon platform={d.platform} kind={d.kind} />
            <div className="flex-1 min-w-0">
              <div className="text-[13px] font-semibold truncate">{d.name}</div>
              <div className="text-[11px] text-[color:var(--text-muted)] flex items-center gap-1.5">
                <span>{d.kind === 'host' ? 'Server' : 'Client'}</span>
                <span>·</span>
                <span>{d.platform}</span>
                {activeHost?.device_id === d.id && (
                  <>
                    <span>·</span>
                    <span className="inline-flex items-center gap-1 text-[#10B981]">
                      <span className="w-1.5 h-1.5 rounded-full bg-[#10B981]" />
                      online
                    </span>
                  </>
                )}
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function SharesTable({ shares }: { shares: Array<{ token: string; file_name: string; created_at: number; expires_at: number | null; downloads: number; url: string }> }) {
  return (
    <div className="bg-[color:var(--surface)] border border-[color:var(--border)] rounded-2xl p-5">
      <table className="w-full text-xs">
        <thead>
          <tr className="text-left text-[color:var(--text-muted)]">
            <th className="py-2 font-medium">File</th>
            <th className="py-2 font-medium">Created</th>
            <th className="py-2 font-medium">Expires</th>
            <th className="py-2 font-medium">Downloads</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-[color:var(--border)]">
          {shares.map((s) => (
            <tr key={s.token}>
              <td className="py-3 text-[13px]">{s.file_name}</td>
              <td className="py-3 text-[color:var(--text-muted)]">{fmtDate(s.created_at)}</td>
              <td className="py-3 text-[color:var(--text-muted)]">{s.expires_at ? fmtDate(s.expires_at) : 'never'}</td>
              <td className="py-3 text-[color:var(--text-muted)]">{s.downloads}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function PlanCard({ className = '', plan, trialDaysRemaining }: { className?: string; plan: string; trialDaysRemaining: number }) {
  return (
    <div className={`rounded-2xl bg-[color:var(--surface)] border border-[color:var(--border)] p-5 ${className}`}>
      <h3 className="text-sm font-semibold mb-3">Your plan</h3>
      <div className="text-2xl font-bold capitalize">{plan}</div>
      {plan === 'trial' && trialDaysRemaining > 0 && (
        <div className="mt-2 text-xs text-[color:var(--accent)] font-medium">
          {trialDaysRemaining} day{trialDaysRemaining === 1 ? '' : 's'} remaining
        </div>
      )}
      <Link href="/pricing" className="mt-4 inline-block text-xs text-[color:var(--accent)] font-medium">See plans →</Link>
    </div>
  );
}

function UpgradeBanner({ className = '' }: { className?: string }) {
  return (
    <div className={`rounded-2xl p-6 text-white flex gap-4 items-center ${className}`} style={{ background: 'linear-gradient(135deg, #8F93F6 0%, #B1A7F9 100%)' }}>
      <div className="flex-1">
        <h3 className="text-lg font-bold mb-2">Unlock Your plan</h3>
        <p className="text-xs opacity-90 mb-4">Lifetime access, unlimited devices, optional cloud backup.</p>
        <Link href="/pricing" className="inline-block bg-white text-[#6E74F2] text-xs font-semibold px-4 py-2 rounded-md hover:bg-white/90">Go Premium</Link>
      </div>
    </div>
  );
}

function fmtDate(unix: number) {
  return new Date(unix * 1000).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
}
