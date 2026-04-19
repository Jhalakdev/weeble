import { NextResponse } from 'next/server';
import { getSessionToken } from '@/lib/session';

// Creates a Stripe Checkout session for the requested plan and 302s to it.
// Stripe is loaded dynamically so the route works in dev without keys.
export async function GET(req: Request) {
  const url = new URL(req.url);
  const plan = url.searchParams.get('plan');
  if (!plan || !['monthly', 'yearly', 'lifetime'].includes(plan)) {
    return NextResponse.json({ error: 'invalid_plan' }, { status: 400 });
  }

  const token = await getSessionToken();
  if (!token) return NextResponse.redirect(new URL('/login', req.url));

  if (!process.env.STRIPE_SECRET_KEY) {
    return NextResponse.json(
      { error: 'stripe_not_configured', message: 'Set STRIPE_SECRET_KEY in .env.local' },
      { status: 503 },
    );
  }

  const Stripe = (await import('stripe')).default;
  const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);

  const priceId =
    plan === 'monthly'
      ? process.env.STRIPE_PRICE_MONTHLY
      : plan === 'yearly'
        ? process.env.STRIPE_PRICE_YEARLY
        : process.env.STRIPE_PRICE_LIFETIME;

  if (!priceId) return NextResponse.json({ error: 'price_not_configured' }, { status: 503 });

  const siteUrl = process.env.NEXT_PUBLIC_SITE_URL || 'http://localhost:3000';

  const session = await stripe.checkout.sessions.create({
    mode: plan === 'lifetime' ? 'payment' : 'subscription',
    line_items: [{ price: priceId, quantity: 1 }],
    success_url: `${siteUrl}/dashboard?checkout=success`,
    cancel_url: `${siteUrl}/pricing?checkout=cancel`,
    client_reference_id: token, // backend can correlate via webhook + this field
  });

  if (!session.url) return NextResponse.json({ error: 'no_session_url' }, { status: 500 });
  return NextResponse.redirect(session.url, 303);
}
