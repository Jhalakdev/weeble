'use client';

import { LogOut } from 'lucide-react';

export function LogoutButton() {
  async function logout() {
    await fetch('/api/auth/logout', { method: 'POST' });
    window.location.href = '/';
  }
  return (
    <button
      onClick={logout}
      className="w-full flex items-center justify-center gap-2 px-4 py-3 rounded-xl border border-red-200 text-red-600 text-[13px] font-medium hover:bg-red-50"
    >
      <LogOut size={16} /> Sign out
    </button>
  );
}
