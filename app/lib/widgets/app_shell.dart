import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/storage_allocator.dart';
import '../state/auth.dart';
import '../state/config.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import 'byte_size.dart';
import 'host_status_pill.dart';
import 'weeber_logo.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({
    super.key,
    required this.title,
    required this.child,
    this.activeRoute,
    this.onCreateNew,
  });

  final String title;
  final Widget child;
  final String? activeRoute;
  final VoidCallback? onCreateNew;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 980;
    final c = context.weeberColors;
    return Scaffold(
      backgroundColor: c.body,
      drawer: wide ? null : Drawer(
        backgroundColor: c.sidebarBg,
        shape: const RoundedRectangleBorder(),
        child: _Sidebar(activeRoute: widget.activeRoute, onCreateNew: widget.onCreateNew),
      ),
      body: Row(
        children: [
          if (wide) _Sidebar(activeRoute: widget.activeRoute, onCreateNew: widget.onCreateNew),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TopBar(title: widget.title, showMenu: !wide),
                Expanded(child: widget.child),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar({required this.title, required this.showMenu});
  final String title;
  final bool showMenu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.weeberColors;
    final themeMode = ref.watch(themeControllerProvider);
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          if (showMenu) Builder(
            builder: (ctx) => IconButton(
              icon: const Icon(Icons.menu, size: 22),
              onPressed: () => Scaffold.of(ctx).openDrawer(),
            ),
          ),
          Expanded(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 420),
              height: 40,
              child: TextField(
                decoration: InputDecoration(
                  hintText: 'Type here to search...',
                  prefixIcon: Icon(Icons.search, size: 18, color: c.textMuted),
                  filled: true,
                  fillColor: c.body,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide.none),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide.none),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: const BorderSide(color: AppTheme.accent, width: 1)),
                  contentPadding: const EdgeInsets.symmetric(vertical: 0),
                ),
              ),
            ),
          ),
          const Spacer(),
          const HostStatusPill(),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Toggle theme',
            icon: Icon(themeMode == WeeberThemeMode.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined, size: 20),
            onPressed: () {
              final next = themeMode == WeeberThemeMode.dark ? WeeberThemeMode.light : WeeberThemeMode.dark;
              ref.read(themeControllerProvider.notifier).setMode(next);
            },
          ),
          IconButton(icon: const Icon(Icons.notifications_outlined, size: 20), onPressed: () {}),
          IconButton(icon: const Icon(Icons.settings_outlined, size: 20), onPressed: () {}),
          const SizedBox(width: 4),
          CircleAvatar(
            radius: 16,
            backgroundColor: AppTheme.accent,
            child: Text(
              _initial(ref.watch(authProvider).accountId ?? 'W'),
              style: GoogleFonts.poppins(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  String _initial(String s) => s.isNotEmpty ? s[0].toUpperCase() : 'W';
}

class _Sidebar extends ConsumerWidget {
  const _Sidebar({this.activeRoute, this.onCreateNew});
  final String? activeRoute;
  final VoidCallback? onCreateNew;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.weeberColors;
    final cfg = ref.watch(appConfigProvider);
    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: c.sidebarBg,
        border: Border(right: BorderSide(color: c.border)),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 24, 20, 20),
              child: WeeberLogo(size: 18),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: OutlinedButton.icon(
                onPressed: onCreateNew,
                icon: const Icon(Icons.add, size: 16, color: AppTheme.accent),
                label: Text(
                  'Create New',
                  style: GoogleFonts.poppins(fontSize: 12, color: AppTheme.accent, fontWeight: FontWeight.w500),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppTheme.accent, width: 1.2),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
            const SizedBox(height: 16),
            _NavSection(items: [
              _NavItemData(icon: Icons.grid_view_rounded, label: 'Dashboard', route: '/drive'),
              _NavItemData(icon: Icons.folder_outlined, label: 'My Drive', route: '/drive'),
              _NavItemData(icon: Icons.insert_drive_file_outlined, label: 'Files', route: '/drive'),
              _NavItemData(icon: Icons.access_time, label: 'Recent', route: '/drive'),
              _NavItemData(icon: Icons.star_border, label: 'Favourite', route: '/drive'),
              _NavItemData(icon: Icons.delete_outline, label: 'Trash', route: '/drive'),
            ], activeRoute: activeRoute),
            const SizedBox(height: 16),
            _NavSection(items: [
              _NavItemData(icon: Icons.devices_outlined, label: 'Devices', route: '/devices'),
              _NavItemData(icon: Icons.link_outlined, label: 'Shares', route: '/drive'),
              _NavItemData(icon: Icons.qr_code_2_outlined, label: 'Pair', route: '/pair/host'),
              _NavItemData(icon: Icons.backup_outlined, label: 'Backup', route: '/backup'),
            ], activeRoute: activeRoute),
            const Spacer(),
            if (cfg.storagePath != null) Padding(
              padding: const EdgeInsets.all(16),
              child: _SidebarStorageCard(allocated: cfg.allocatedBytes ?? 0),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: _NavItem(
                data: _NavItemData(icon: Icons.logout, label: 'Log out', route: null),
                active: false,
                onTap: () => ref.read(authProvider.notifier).logout(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavSection extends StatelessWidget {
  const _NavSection({required this.items, required this.activeRoute});
  final List<_NavItemData> items;
  final String? activeRoute;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final item in items) _NavItem(data: item, active: item.route == activeRoute)],
      ),
    );
  }
}

class _NavItemData {
  _NavItemData({required this.icon, required this.label, required this.route});
  final IconData icon;
  final String label;
  final String? route;
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.data, required this.active, this.onTap});
  final _NavItemData data;
  final bool active;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    // Primary route (/drive) uses `go` (top-level destination).
    // Secondary routes use `push` so the AppBar's back button works and
    // users aren't stuck on a dead-end screen.
    final router = GoRouter.of(context);
    return InkWell(
      onTap: onTap ?? (data.route != null ? () {
        if (data.route == '/drive') {
          router.go(data.route!);
        } else {
          router.push(data.route!);
        }
      } : null),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: active ? c.sidebarActiveBg : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(data.icon, size: 17, color: active ? AppTheme.accent : c.textMuted),
            const SizedBox(width: 12),
            Expanded(child: Text(
              data.label,
              style: GoogleFonts.poppins(
                fontSize: 13,
                color: active ? AppTheme.accent : c.textMuted,
                fontWeight: active ? FontWeight.w500 : FontWeight.w400,
              ),
            )),
          ],
        ),
      ),
    );
  }
}

class _SidebarStorageCard extends ConsumerStatefulWidget {
  const _SidebarStorageCard({required this.allocated});
  final int allocated;
  @override
  ConsumerState<_SidebarStorageCard> createState() => _SidebarStorageCardState();
}

class _SidebarStorageCardState extends ConsumerState<_SidebarStorageCard> {
  int _used = 0;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final cfg = ref.read(appConfigProvider);
    if (cfg.storagePath == null) return;
    final used = await StorageAllocator.usedBytes(cfg.storagePath!);
    if (mounted) setState(() { _used = used; _loaded = true; });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    final allocated = widget.allocated;
    final pct = allocated == 0 ? 0.0 : (_used / allocated).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: c.body, borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.cloud_outlined, size: 16, color: AppTheme.accent),
            const SizedBox(width: 6),
            Text('Storage', style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: c.textPrimary)),
          ]),
          const SizedBox(height: 10),
          if (_loaded) ...[
            Text(
              '${formatBytes(_used)} / ${formatBytes(allocated)} Used',
              style: GoogleFonts.poppins(fontSize: 11, color: c.textMuted),
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: pct, minHeight: 5,
                backgroundColor: c.border,
                valueColor: const AlwaysStoppedAnimation(AppTheme.accent),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${(pct * 100).toStringAsFixed(0)}% Full · ${formatBytes(allocated - _used)} Free',
              style: GoogleFonts.poppins(fontSize: 10, color: c.textMuted),
            ),
          ] else
            const SizedBox(height: 24, child: LinearProgressIndicator()),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () {},
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.accent,
              minimumSize: const Size.fromHeight(32),
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              textStyle: GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.w500),
            ),
            child: const Text('Buy Storage'),
          ),
        ],
      ),
    );
  }
}
