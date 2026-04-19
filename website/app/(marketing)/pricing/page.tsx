import Link from 'next/link';

const plans = [
  {
    name: 'Trial',
    price: 'Free',
    period: '7 days',
    cta: 'Start trial',
    href: '/signup',
    features: ['All features unlocked', 'Up to 3 devices', 'No credit card required'],
  },
  {
    name: 'Monthly',
    price: '$4.99',
    period: 'per month',
    cta: 'Subscribe',
    href: '/api/billing/checkout?plan=monthly',
    features: ['All features', 'Up to 5 devices', 'Cancel anytime'],
    highlight: true,
  },
  {
    name: 'Yearly',
    price: '$49',
    period: 'per year',
    cta: 'Subscribe',
    href: '/api/billing/checkout?plan=yearly',
    features: ['All features', 'Up to 5 devices', '2 months free vs monthly'],
  },
  {
    name: 'Lifetime',
    price: '$199',
    period: 'one-time',
    cta: 'Buy lifetime',
    href: '/api/billing/checkout?plan=lifetime',
    features: ['All features forever', 'Up to 10 devices', 'Free updates'],
  },
];

export default function PricingPage() {
  return (
    <div className="mx-auto max-w-6xl px-6 py-16">
      <h1 className="text-4xl font-semibold text-center">Simple pricing</h1>
      <p className="mt-3 text-center text-slate-600">
        Pay for the software once. Use as much storage as your hard drive can hold.
      </p>

      <div className="mt-12 grid gap-6 md:grid-cols-4">
        {plans.map((plan) => (
          <div
            key={plan.name}
            className={`rounded-lg border p-6 flex flex-col ${
              plan.highlight ? 'border-slate-900 shadow-lg' : 'border-slate-200'
            }`}
          >
            <h3 className="text-lg font-semibold">{plan.name}</h3>
            <div className="mt-4">
              <span className="text-3xl font-semibold">{plan.price}</span>
              <span className="ml-1 text-slate-500">/ {plan.period}</span>
            </div>
            <ul className="mt-6 space-y-2 text-sm text-slate-600 flex-1">
              {plan.features.map((f) => (
                <li key={f}>· {f}</li>
              ))}
            </ul>
            <Link
              href={plan.href}
              className={`mt-6 block rounded-md px-4 py-2 text-center text-sm font-medium ${
                plan.highlight
                  ? 'bg-slate-900 text-white hover:bg-slate-700'
                  : 'border border-slate-300 hover:bg-slate-50'
              }`}
            >
              {plan.cta}
            </Link>
          </div>
        ))}
      </div>
    </div>
  );
}
