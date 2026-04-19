// Shown by Next.js while /dashboard is server-rendering. Looks like the
// real layout so navigation feels instant on a slow phone.
export default function Loading() {
  return (
    <div className="px-3 md:px-6 py-3 md:py-6 space-y-4 md:space-y-6 animate-pulse">
      <div className="rounded-2xl bg-[color:var(--surface)] border border-[color:var(--border)] p-6 h-[112px]" />
      <div className="grid grid-cols-1 lg:grid-cols-11 gap-4">
        <div className="lg:col-span-5 rounded-2xl bg-[color:var(--surface)] border border-[color:var(--border)] h-[280px]" />
        <div className="lg:col-span-6 rounded-2xl bg-[color:var(--surface)] border border-[color:var(--border)] h-[280px]" />
      </div>
    </div>
  );
}
