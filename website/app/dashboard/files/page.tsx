import { redirect } from 'next/navigation';
import { api } from '@/lib/api';
import { getSessionToken } from '@/lib/session';
import { FilesPanel } from '../files-panel';

// Files-only screen — what mobile users land on when they tap the
// "Files" bottom tab. Same FilesPanel as Home, but full-screen with
// no other dashboard widgets competing for attention.
export default async function DashboardFilesPage() {
  const token = await getSessionToken();
  if (!token) redirect('/login');

  const [activeHost, filesRes] = await Promise.all([
    api.activeHost(token),
    api.relayFiles(token),
  ]);
  const initialFiles = filesRes?.files ?? [];

  return (
    // Edge-to-edge on mobile (no side padding) so files appear larger
    // and use the full screen width — feels "zoomed in".
    <div className="px-0 md:px-6 py-0 md:py-6">
      <FilesPanel initialFiles={initialFiles} hostOnline={!!activeHost} />
    </div>
  );
}
