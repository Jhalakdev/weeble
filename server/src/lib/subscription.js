// Pure logic for "is this account allowed to use the service right now?"
// Called on every endpoint lookup. Must stay cheap.

const TRIAL_DAYS = parseInt(process.env.TRIAL_DAYS || '7', 10);
const SECONDS_PER_DAY = 86400;

export function isAccountActive(account, now = Math.floor(Date.now() / 1000)) {
  if (!account) return false;

  switch (account.subscription_status) {
    case 'active':
      return true;
    case 'trialing': {
      const trialEnd = account.trial_started_at + TRIAL_DAYS * SECONDS_PER_DAY;
      return now < trialEnd;
    }
    case 'past_due':
      // Grace period: keep working for 3 days after a failed payment.
      return account.subscription_renews_at && now < account.subscription_renews_at + 3 * SECONDS_PER_DAY;
    case 'canceled':
      // Lifetime users have status 'active'. Canceled = no access.
      return false;
    default:
      return false;
  }
}

export function trialDaysRemaining(account, now = Math.floor(Date.now() / 1000)) {
  if (account.subscription_status !== 'trialing') return 0;
  const trialEnd = account.trial_started_at + TRIAL_DAYS * SECONDS_PER_DAY;
  return Math.max(0, Math.ceil((trialEnd - now) / SECONDS_PER_DAY));
}
