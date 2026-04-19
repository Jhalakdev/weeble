import Link from 'next/link';
import { redirect } from 'next/navigation';
import { Sparkles } from 'lucide-react';
import { api } from '@/lib/api';
import { getSessionToken } from '@/lib/session';
import { LiveStorageCard } from '@/components/LiveStorageCard';
import { LogoutButton } from './client';

export default async function DashboardAccountPage() {
  const token = await getSessionToken();
  if (!token) redirect('/login');

  const status = await api.billingStatus(token);
  const inTrial = status.plan === 'trial' && status.trial_days_remaining > 0;
  const planLabel = status.plan === 'trial' ? 'Free trial' : status.plan;

  return (
    <div className="px-3 md:px-6 py-3 md:py-6 space-y-4 max-w-2xl">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Account</h1>
        <p className="text-[12px] text-[color:var(--text-muted)] mt-1">Plan, storage, and sign-out.</p>
      </div>

      {/* PLAN — was on the homepage; lives here now (no duplicates anywhere). */}
      <PlanCard plan={planLabel} status={status.status} inTrial={inTrial} daysLeft={status.trial_days_remaining} />

      {/* UPGRADE banner — was on the homepage; here now, hidden if already on a paid plan. */}
      {status.plan === 'trial' && <UpgradeBanner />}

      {/* Storage card — single source of truth across the whole app. */}
      <LiveStorageCard variant="block" />

      <div className="rounded-2xl border border-[color:var(--border)] bg-[color:var(--surface)] p-5">
        <div className="text-[11px] text-[color:var(--text-muted)] uppercase tracking-[0.08em] font-semibold mb-2">About Weeber</div>
        <p className="text-[13px] leading-relaxed text-[color:var(--text-muted)]">
          Your files live on your computer, not on a remote server. A persistent encrypted tunnel lets every device you own
          reach those files — no router configuration, no cloud storage bills.
        </p>
      </div>

      <LogoutButton />
    </div>
  );
}

function PlanCard({ plan, status, inTrial, daysLeft }: { plan: string; status: string; inTrial: boolean; daysLeft: number }) {
  return (
    <div className="rounded-2xl border border-[color:var(--border)] bg-[color:var(--surface)] p-5 shadow-sm">
      <div className="text-[11px] text-[color:var(--text-muted)] uppercase tracking-[0.08em] font-semibold mb-2">Your plan</div>
      <div className="flex items-end justify-between gap-3">
        <div>
          <div className="text-[28px] font-bold capitalize tracking-tight">{plan}</div>
          <div className="text-[12px] text-[color:var(--text-muted)] mt-1">
            {inTrial ? `${daysLeft} day${daysLeft === 1 ? '' : 's'} remaining` : `Status: ${status}`}
          </div>
        </div>
        {inTrial && (
          <Link
            href="/pricing"
            className="inline-flex items-center gap-1.5 text-[12px] font-semibold bg-[color:var(--accent)] hover:bg-[color:var(--accent-hover)] text-white px-4 py-2.5 rounded-lg shadow-sm"
          >
            <Sparkles size={14} /> Upgrade
          </Link>
        )}
      </div>
    </div>
  );
}

function UpgradeBanner() {
  return (
    <div
      className="rounded-2xl p-6 text-white flex items-center justify-between gap-4 overflow-hidden relative"
      style={{ background: 'linear-gradient(135deg, #8F93F6 0%, #6E74F2 50%, #5B61EE 100%)' }}
    >
      <div className="absolute inset-0 opacity-20" style={{ background: 'radial-gradient(circle at 80% 20%, rgba(255,255,255,0.4) 0%, transparent 50%)' }} />
      <div className="relative flex-1">
        <div className="text-[10px] uppercase tracking-[0.12em] font-semibold opacity-80 mb-1">Premium</div>
        <h3 className="text-xl font-bold mb-1.5">Unlock Your plan</h3>
        <p className="text-[12px] opacity-90 max-w-xs">Lifetime access, unlimited devices, optional cloud backup.</p>
      </div>
      <Link
        href="/pricing"
        className="relative inline-flex items-center gap-1.5 bg-white text-[#6E74F2] text-[12px] font-bold px-5 py-2.5 rounded-lg shadow-md hover:bg-white/95 whitespace-nowrap"
      >
        Go Premium
      </Link>
    </div>
  );
}
