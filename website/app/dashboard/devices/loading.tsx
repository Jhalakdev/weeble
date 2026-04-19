export default function Loading() {
  return (
    <div className="px-3 md:px-6 py-3 md:py-6 space-y-4 animate-pulse">
      <div className="space-y-1.5">
        <div className="h-6 w-32 bg-[color:var(--surface)] rounded" />
        <div className="h-3 w-44 bg-[color:var(--surface)] rounded" />
      </div>
      <div className="rounded-2xl bg-[color:var(--surface)] border border-[color:var(--border)] h-[120px]" />
      <div className="rounded-2xl bg-[color:var(--surface)] border border-[color:var(--border)] h-[200px]" />
    </div>
  );
}
