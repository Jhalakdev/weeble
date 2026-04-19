import { redirect } from 'next/navigation';
import { DashboardShell } from '@/components/DashboardShell';
import { getSessionToken } from '@/lib/session';
import { api } from '@/lib/api';

export default async function DashboardLayout({ children }: { children: React.ReactNode }) {
  const token = await getSessionToken();
  if (!token) redirect('/login');

  let status;
  try {
    status = await api.billingStatus(token);
  } catch {
    redirect('/login');
  }

  return (
    <DashboardShell plan={status.plan} planStatus={status.status} trialDaysRemaining={status.trial_days_remaining}>
      {children}
    </DashboardShell>
  );
}
