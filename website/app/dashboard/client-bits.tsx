'use client';

import { Laptop, Smartphone, Cloud, Monitor } from 'lucide-react';
import { useRouter } from 'next/navigation';

export function DeviceIcon({ platform, kind }: { platform: string; kind: string }) {
  if (kind === 'host') {
    return (
      <div className="w-10 h-10 rounded-lg bg-[color:var(--accent-muted)] text-[color:var(--accent)] flex items-center justify-center">
        <Cloud size={20} />
      </div>
    );
  }
  const Icon = platform === 'ios' || platform === 'android' ? Smartphone : platform === 'macos' ? Laptop : Monitor;
  return (
    <div className="w-10 h-10 rounded-lg bg-[color:var(--accent-muted)] text-[color:var(--accent)] flex items-center justify-center">
      <Icon size={20} />
    </div>
  );
}

export function CreateNewButton() {
  const router = useRouter();
  return (
    <button
      onClick={() => {
        alert('To upload files, install the Weeber app on your computer or phone. Click "Download" in the sidebar.');
      }}
      className="w-full flex items-center justify-center gap-2 py-2 rounded-lg border border-[color:var(--accent)] text-[color:var(--accent)] text-xs font-medium hover:bg-[color:var(--accent-muted)]"
    >
      <span className="text-lg leading-none">+</span> Create New
    </button>
  );
}
