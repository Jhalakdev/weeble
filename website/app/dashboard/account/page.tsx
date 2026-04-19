import { redirect } from 'next/navigation';
import { api } from '@/lib/api';
import { getSessionToken } from '@/lib/session';
import { LiveStorageCard } from '@/components/LiveStorageCard';
import { LogoutButton } from './client';

export default async function DashboardAccountPage() {
  const token = await getSessionToken();
  if (!token) redirect('/login');

  const status = await api.billingStatus(token);

  return (
    <div className="px-4 md:px-6 py-4 md:py-6 space-y-4 max-w-2xl">
      <h1 className="text-xl font-semibold">Account</h1>

      <LiveStorageCard variant="block" />

      <div className="rounded-2xl border border-[color:var(--border)] bg-[color:var(--surface)] p-5">
        <div className="text-[12px] text-[color:var(--text-muted)] uppercase tracking-wider mb-2">Plan</div>
        <div className="text-2xl font-bold capitalize">{status.plan === 'trial' ? 'Free trial' : status.plan}</div>
        <div className="text-[12px] text-[color:var(--text-muted)] mt-1">
          {status.plan === 'trial' && status.trial_days_remaining > 0
            ? `${status.trial_days_remaining} day${status.trial_days_remaining === 1 ? '' : 's'} remaining · status: ${status.status}`
            : `Status: ${status.status}`}
        </div>
      </div>

      <div className="rounded-2xl border border-[color:var(--border)] bg-[color:var(--surface)] p-5">
        <div className="text-[12px] text-[color:var(--text-muted)] uppercase tracking-wider mb-2">About Weeber</div>
        <p className="text-[13px] leading-relaxed text-[color:var(--text-muted)]">
          Your files live on your computer, not on a remote server. A persistent encrypted tunnel
          lets every device you own reach those files — no router configuration, no cloud storage bills.
        </p>
      </div>

      <LogoutButton />
    </div>
  );
}
