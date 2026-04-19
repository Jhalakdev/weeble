import { getDb } from '../db/index.js';
import { trialDaysRemaining } from '../lib/subscription.js';

export default async function billingRoutes(app) {
  // Lightweight status endpoint — clients call this on launch to display trial
  // banner / upgrade prompt. Cheap to call, no Stripe round-trip.
  app.get('/v1/billing/status', { preHandler: app.requireAuth }, async (req) => {
    const db = getDb();
    const account = db.prepare(`
      SELECT plan, subscription_status, subscription_renews_at, trial_started_at
      FROM accounts WHERE id = ?
    `).get(req.auth.accountId);

    return {
      plan: account.plan,
      status: account.subscription_status,
      renews_at: account.subscription_renews_at,
      trial_days_remaining: trialDaysRemaining(account),
    };
  });

  // Stripe webhook receiver. Stripe will retry on failure, so handlers must be idempotent.
  // Verifies signature, updates account row, returns 2xx.
  app.post('/v1/billing/stripe/webhook', {
    config: { rawBody: true },
  }, async (req, reply) => {
    if (!process.env.STRIPE_SECRET_KEY) {
      return reply.code(503).send({ error: 'stripe_not_configured' });
    }
    const Stripe = (await import('stripe')).default;
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);

    let event;
    try {
      event = stripe.webhooks.constructEvent(
        req.rawBody,
        req.headers['stripe-signature'],
        process.env.STRIPE_WEBHOOK_SECRET,
      );
    } catch {
      return reply.code(400).send({ error: 'invalid_signature' });
    }

    const db = getDb();
    switch (event.type) {
      case 'customer.subscription.created':
      case 'customer.subscription.updated': {
        const sub = event.data.object;
        const plan = sub.items.data[0]?.price?.recurring?.interval === 'year' ? 'yearly' : 'monthly';
        db.prepare(`
          UPDATE accounts SET
            plan = ?,
            subscription_status = ?,
            subscription_renews_at = ?
          WHERE stripe_customer_id = ?
        `).run(plan, sub.status, sub.current_period_end, sub.customer);
        break;
      }
      case 'customer.subscription.deleted': {
        const sub = event.data.object;
        db.prepare(`
          UPDATE accounts SET subscription_status = 'canceled' WHERE stripe_customer_id = ?
        `).run(sub.customer);
        break;
      }
      // Other events ignored.
    }

    return { received: true };
  });
}
