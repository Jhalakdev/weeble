import { redirect } from 'next/navigation';
import { api } from '@/lib/api';
import { getSessionToken } from '@/lib/session';
import { DeviceIcon } from '../client-bits';

function fmtAgo(unix: number) {
  const delta = Math.floor(Date.now() / 1000) - unix;
  if (delta < 60) return 'just now';
  if (delta < 3600) return `${Math.floor(delta / 60)} min ago`;
  if (delta < 86400) return `${Math.floor(delta / 3600)} h ago`;
  return `${Math.floor(delta / 86400)} d ago`;
}

export default async function DashboardDevicesPage() {
  const token = await getSessionToken();
  if (!token) redirect('/login');

  const [devicesRes, activeHost] = await Promise.all([
    api.listDevices(token).catch(() => ({ devices: [] })),
    api.activeHost(token),
  ]);
  const devices = devicesRes.devices;

  return (
    <div className="px-4 md:px-6 py-4 md:py-6 space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">Devices</h1>
          <p className="text-xs text-[color:var(--text-muted)] mt-0.5">{devices.length} device{devices.length === 1 ? '' : 's'} on this account</p>
        </div>
      </div>
      {devices.length === 0 ? (
        <div className="rounded-2xl bg-[color:var(--surface)] border border-[color:var(--border)] p-8 text-center">
          <div className="text-sm font-semibold mb-1">No devices yet</div>
          <p className="text-xs text-[color:var(--text-muted)] max-w-sm mx-auto">Install the Weeber app on your computer to create a host, then on each phone you want to access from.</p>
        </div>
      ) : (
        <div className="rounded-2xl bg-[color:var(--surface)] border border-[color:var(--border)] divide-y divide-[color:var(--border)]">
          {devices.map((d) => (
            <div key={d.id} className="flex items-center gap-3 p-4">
              <DeviceIcon platform={d.platform} kind={d.kind} />
              <div className="flex-1 min-w-0">
                <div className="text-[14px] font-semibold truncate flex items-center gap-2">
                  {d.name}
                  {activeHost?.device_id === d.id && (
                    <span className="inline-flex items-center gap-1 text-[10px] text-[#10B981] font-medium">
                      <span className="w-1.5 h-1.5 rounded-full bg-[#10B981]" /> active host
                    </span>
                  )}
                </div>
                <div className="text-[11px] text-[color:var(--text-muted)]">
                  {d.kind === 'host' ? 'Server' : 'Client'} · {d.platform} · last seen {fmtAgo(d.last_seen_at)}
                </div>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
