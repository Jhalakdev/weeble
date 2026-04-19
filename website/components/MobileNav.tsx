'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { Home, FolderOpen, Cloud, User } from 'lucide-react';

const TABS = [
  { icon: Home, label: 'Home', href: '/dashboard' },
  { icon: FolderOpen, label: 'Files', href: '/dashboard/files' },
  { icon: Cloud, label: 'Devices', href: '/dashboard/devices' },
  { icon: User, label: 'Account', href: '/dashboard/account' },
];

export function MobileNav() {
  const pathname = usePathname() ?? '';
  return (
    <nav
      className="md:hidden fixed bottom-0 left-0 right-0 z-40 bg-[color:var(--surface)] border-t border-[color:var(--border)] px-2 pb-safe"
      style={{ paddingBottom: 'calc(env(safe-area-inset-bottom, 0) + 6px)' }}
    >
      <div className="flex items-stretch justify-around pt-2">
        {TABS.map((tab) => {
          // Exact match for the dashboard root, prefix-match for subroutes.
          const active = tab.href === '/dashboard' ? pathname === '/dashboard' : pathname.startsWith(tab.href);
          return (
            <Link
              key={tab.label}
              href={tab.href}
              className={`press flex-1 flex flex-col items-center gap-1 py-1 rounded-xl ${
                active ? 'text-[color:var(--accent)]' : 'text-[color:var(--text-muted)]'
              }`}
            >
              <tab.icon size={22} strokeWidth={active ? 2.2 : 1.8} />
              <span className="text-[10px] font-medium">{tab.label}</span>
            </Link>
          );
        })}
      </div>
    </nav>
  );
}
