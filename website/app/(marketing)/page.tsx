import Link from 'next/link';

export default function HomePage() {
  return (
    <div>
      <section className="mx-auto max-w-6xl px-6 pt-20 pb-16 text-center">
        <h1 className="text-5xl md:text-6xl font-semibold tracking-tight">
          Your PC. Your cloud.
        </h1>
        <p className="mt-6 text-xl text-slate-600 max-w-2xl mx-auto">
          Weeber turns the laptop or desktop you already own into a private cloud drive.
          Access your files from any device — without paying monthly for someone
          else&apos;s servers.
        </p>
        <div className="mt-10 flex items-center justify-center gap-4">
          <Link
            href="/signup"
            className="rounded-md bg-slate-900 px-5 py-3 text-white text-base font-medium hover:bg-slate-700"
          >
            Start free 7-day trial
          </Link>
          <Link
            href="/pricing"
            className="rounded-md border border-slate-300 px-5 py-3 text-base font-medium hover:bg-slate-50"
          >
            See pricing
          </Link>
        </div>
        <p className="mt-4 text-sm text-slate-500">No credit card required.</p>
      </section>

      <section className="bg-slate-50 border-y border-slate-200">
        <div className="mx-auto max-w-6xl px-6 py-16 grid gap-10 md:grid-cols-3">
          <Feature
            title="Pay for software, not storage"
            body="One flat price. Use as many gigabytes as your hard drive can hold. No surprise bills when your library grows."
          />
          <Feature
            title="Files never leave your hardware"
            body="Direct device-to-device transfers. Your data doesn't sit on our servers — only on the machines you own."
          />
          <Feature
            title="Works on every device"
            body="Windows, macOS, Linux, iPhone, Android. One library, browsable from anywhere with a Drive-like UI."
          />
        </div>
      </section>

      <section className="mx-auto max-w-6xl px-6 py-20">
        <h2 className="text-3xl font-semibold text-center">How it works</h2>
        <ol className="mt-10 grid gap-8 md:grid-cols-4">
          <Step n={1} title="Sign up" body="Create your account in seconds." />
          <Step n={2} title="Install" body="Download the Weeber app on your PC, Mac, or Linux machine." />
          <Step n={3} title="Allocate space" body="Pick how much of your drive to dedicate. Resize anytime." />
          <Step n={4} title="Access anywhere" body="Pair your phone with a QR code. Done." />
        </ol>
      </section>
    </div>
  );
}

function Feature({ title, body }: { title: string; body: string }) {
  return (
    <div>
      <h3 className="text-lg font-semibold">{title}</h3>
      <p className="mt-2 text-slate-600">{body}</p>
    </div>
  );
}

function Step({ n, title, body }: { n: number; title: string; body: string }) {
  return (
    <li className="relative">
      <div className="text-sm font-mono text-slate-400">{String(n).padStart(2, '0')}</div>
      <h3 className="mt-2 font-semibold">{title}</h3>
      <p className="mt-1 text-sm text-slate-600">{body}</p>
    </li>
  );
}
