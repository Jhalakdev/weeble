export default function Loading() {
  return (
    <div className="px-0 md:px-6 py-0 md:py-6 animate-pulse">
      <div className="bg-[color:var(--surface)] md:border md:border-[color:var(--border)] md:rounded-2xl p-3 md:p-5 space-y-4">
        <div className="h-12 md:h-9 bg-[color:var(--body)] rounded-full md:rounded-lg" />
        <div className="flex gap-2 overflow-hidden">
          {Array.from({ length: 6 }).map((_, i) => (
            <div key={i} className="h-7 w-20 bg-[color:var(--body)] rounded-full flex-shrink-0" />
          ))}
        </div>
        <div className="space-y-3 pt-2">
          {Array.from({ length: 8 }).map((_, i) => (
            <div key={i} className="flex items-center gap-3">
              <div className="w-[54px] h-[54px] md:w-10 md:h-10 rounded-xl md:rounded-lg bg-[color:var(--body)]" />
              <div className="flex-1 space-y-2">
                <div className="h-3 bg-[color:var(--body)] rounded w-3/4" />
                <div className="h-2 bg-[color:var(--body)] rounded w-1/3" />
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
