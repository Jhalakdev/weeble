'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useEffect, useState } from 'react';
import {
  LayoutGrid, Link as LinkIcon, Download, DollarSign, Cloud,
  Bell, Moon, Sun, Settings, Search, Plus, LogOut,
} from 'lucide-react';
import { HostStatusPill } from './HostStatusPill';
import { MobileNav } from './MobileNav';

type NavItem = { icon: React.ReactNode; label: string; href: string };

const NAV_PRIMARY: NavItem[] = [
  { icon: <LayoutGrid size={16} />, label: 'Dashboard', href: '/dashboard' },
  { icon: <Cloud size={16} />, label: 'Devices', href: '/dashboard' },
  { icon: <LinkIcon size={16} />, label: 'Shares', href: '/dashboard' },
  { icon: <Download size={16} />, label: 'Download', href: '/download' },
  { icon: <DollarSign size={16} />, label: 'Pricing', href: '/pricing' },
];

export function DashboardShell({
  children,
  plan,
  planStatus,
  trialDaysRemaining,
}: {
  children: React.ReactNode;
  plan: string;
  planStatus: string;
  trialDaysRemaining: number;
}) {
  const [isDark, setIsDark] = useState(false);

  useEffect(() => {
    const saved = localStorage.getItem('weeber-theme');
    const prefersDark = saved === 'dark' || (saved == null && window.matchMedia('(prefers-color-scheme: dark)').matches);
    setIsDark(prefersDark);
    document.documentElement.classList.toggle('dark', prefersDark);
  }, []);

  const toggleTheme = () => {
    const next = !isDark;
    setIsDark(next);
    localStorage.setItem('weeber-theme', next ? 'dark' : 'light');
    document.documentElement.classList.toggle('dark', next);
  };

  return (
    <div className="min-h-screen flex bg-[color:var(--body)] text-[color:var(--text-primary)]">
      {/* Desktop sidebar: hidden below md */}
      <div className="hidden md:flex">
        <Sidebar />
      </div>
      <div className="flex-1 flex flex-col min-w-0">
        <TopBar isDark={isDark} onToggleTheme={toggleTheme} plan={plan} />
        {trialDaysRemaining > 0 && plan === 'trial' && (
          <div className="bg-[color:var(--accent-muted)] border-b border-[color:var(--border)] px-4 md:px-6 py-2 text-xs text-[color:var(--accent)] font-medium text-center md:text-left">
            {trialDaysRemaining} day{trialDaysRemaining === 1 ? '' : 's'} left in your free trial · {' '}
            <Link href="/pricing" className="underline">upgrade now</Link>
          </div>
        )}
        {/* Extra bottom space on mobile so FAB + bottom nav don't overlap the last item */}
        <main className="flex-1 overflow-auto pb-24 md:pb-0">{children}</main>
      </div>
      <MobileNav />
    </div>
  );
}

function Sidebar() {
  const pathname = usePathname();
  return (
    <aside className="w-60 shrink-0 bg-[color:var(--sidebar)] border-r border-[color:var(--border)] flex flex-col">
      <div className="px-5 py-6">
        <Link href="/dashboard" className="flex items-center gap-2">
          <span className="inline-flex h-8 w-8 items-center justify-center rounded-lg bg-gradient-to-br from-[#8f93f6] to-[#afb3fa]">
            <Cloud size={16} className="text-white" />
          </span>
          <span className="text-lg"><span className="font-light">Wee</span><span className="font-bold">BER</span></span>
        </Link>
      </div>
      <div className="px-4 mb-3">
        <Link
          href="/download"
          className="w-full flex items-center justify-center gap-2 py-2 rounded-lg border border-[color:var(--accent)] text-[color:var(--accent)] text-xs font-medium hover:bg-[color:var(--accent-muted)]"
        >
          <Plus size={14} /> Install App
        </Link>
      </div>
      <nav className="px-2.5 flex-1 overflow-auto">
        <SidebarSection items={NAV_PRIMARY} active={pathname} />
      </nav>
      <div className="p-4">
        <StorageCard />
      </div>
      <div className="px-4 pb-4">
        <button
          onClick={async () => { await fetch('/api/auth/logout', { method: 'POST' }); window.location.href = '/'; }}
          className="w-full flex items-center gap-3 px-3.5 py-2.5 rounded-lg text-xs text-[color:var(--text-muted)] hover:bg-[color:var(--accent-muted)]"
        >
          <LogOut size={16} /> Log out
        </button>
      </div>
    </aside>
  );
}

function SidebarSection({ items, active }: { items: NavItem[]; active: string | null }) {
  return (
    <ul className="flex flex-col gap-0.5">
      {items.map((it) => {
        const isActive = active === it.href;
        return (
          <li key={it.label}>
            <Link
              href={it.href}
              className={`flex items-center gap-3 px-3.5 py-2.5 rounded-lg text-[13px] transition-colors ${
                isActive
                  ? 'bg-[color:var(--sidebar-active-bg)] text-[color:var(--accent)] font-medium'
                  : 'text-[color:var(--text-muted)] hover:bg-[color:var(--accent-muted)]'
              }`}
            >
              {it.icon}
              <span>{it.label}</span>
            </Link>
          </li>
        );
      })}
    </ul>
  );
}

function StorageCard() {
  return (
    <div className="bg-[color:var(--body)] rounded-xl p-3.5">
      <div className="flex items-center gap-1.5 mb-2.5">
        <Cloud size={14} className="text-[color:var(--accent)]" />
        <span className="text-[13px] font-semibold">Storage</span>
      </div>
      <div className="text-[11px] text-[color:var(--text-muted)] mb-1.5">17.1 GB / 20 GB Used</div>
      <div className="h-1 rounded-full bg-[color:var(--border)] overflow-hidden mb-1.5">
        <div className="h-full rounded-full bg-[color:var(--accent)]" style={{ width: '75%' }} />
      </div>
      <div className="text-[10px] text-[color:var(--text-muted)] mb-3">75% Full · 3.9 GB Free</div>
      <Link
        href="/pricing"
        className="block text-center bg-[color:var(--accent)] hover:bg-[color:var(--accent-hover)] text-white text-[11px] font-medium py-2 rounded-md"
      >
        Buy Storage
      </Link>
    </div>
  );
}

function TopBar({ isDark, onToggleTheme, plan }: { isDark: boolean; onToggleTheme: () => void; plan: string }) {
  return (
    <header
      className="flex items-center gap-2 md:gap-4 px-4 md:px-6 bg-[color:var(--surface)] border-b border-[color:var(--border)] pt-safe"
      style={{ minHeight: '64px', paddingTop: 'calc(env(safe-area-inset-top, 0) + 0px)' }}
    >
      {/* Mobile: show logo instead of full search */}
      <Link href="/dashboard" className="md:hidden flex items-center gap-2 pl-1">
        <span className="inline-flex h-8 w-8 items-center justify-center rounded-lg bg-gradient-to-br from-[#8f93f6] to-[#afb3fa]">
          <Cloud size={15} className="text-white" />
        </span>
      </Link>

      {/* Desktop search bar */}
      <div className="hidden md:block relative max-w-md flex-1">
        <Search size={16} className="absolute left-3.5 top-1/2 -translate-y-1/2 text-[color:var(--text-muted)]" />
        <input
          type="text"
          placeholder="Type here to search..."
          className="w-full h-10 bg-[color:var(--body)] rounded-full pl-10 pr-4 text-[13px] placeholder:text-[color:var(--text-muted)] focus:outline-none focus:ring-1 focus:ring-[color:var(--accent)]"
        />
      </div>
      <div className="flex-1" />

      <HostStatusPill compact />

      <div className="flex items-center gap-1">
        <span className="hidden md:inline text-[10px] uppercase tracking-wider text-[color:var(--accent)] font-semibold bg-[color:var(--accent-muted)] px-2.5 py-1 rounded-full">
          {plan}
        </span>
        <IconBtn onClick={onToggleTheme} title="Toggle theme">
          {isDark ? <Sun size={18} /> : <Moon size={18} />}
        </IconBtn>
        <IconBtn title="Notifications" className="hidden md:flex"><Bell size={18} /></IconBtn>
        <IconBtn title="Settings" className="hidden md:flex"><Settings size={18} /></IconBtn>
        <div className="ml-1 w-9 h-9 rounded-full bg-[color:var(--accent)] flex items-center justify-center text-white font-semibold text-sm">W</div>
      </div>
    </header>
  );
}

function IconBtn({ children, title, onClick, className = '' }: { children: React.ReactNode; title?: string; onClick?: () => void; className?: string }) {
  return (
    <button
      title={title}
      onClick={onClick}
      className={`press w-9 h-9 rounded-lg flex items-center justify-center text-[color:var(--text-muted)] hover:bg-[color:var(--accent-muted)] hover:text-[color:var(--accent)] ${className}`}
    >
      {children}
    </button>
  );
}
