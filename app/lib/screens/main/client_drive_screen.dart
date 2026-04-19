import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../services/favorites_service.dart';
import '../../services/host_lifecycle.dart';
import '../../services/relay_client.dart';
import '../../state/host_role.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/byte_size.dart';
import '../../widgets/file_preview.dart';
import '../../widgets/mobile_storage_card.dart';

enum DriveFilter { myDrive, recent, favorites, trash }

/// Client drive — used by mobile (iOS/Android) and any desktop that isn't
/// the active host. Talks to the VPS relay (no UPnP / port forward
/// required). Auto-polls every 4s so cross-device uploads appear.
///
/// `filter` decides what the screen shows:
///   - myDrive → all live files (default)
///   - recent → live files sorted by created_at desc, top 50
///   - favorites → live files in the local FavoritesService set
///   - trash → soft-deleted files (loaded with include_deleted=true)
class ClientDriveScreen extends ConsumerStatefulWidget {
  const ClientDriveScreen({super.key, this.filter = DriveFilter.myDrive});
  final DriveFilter filter;
  @override
  ConsumerState<ClientDriveScreen> createState() => _ClientDriveScreenState();
}

class _ClientDriveScreenState extends ConsumerState<ClientDriveScreen> {
  bool _loading = true;
  String? _error;
  List<RelayFile> _files = [];
  List<RelayCrumb> _path = [];
  RelayStats? _stats;
  Set<String> _favorites = {};
  String? _currentFolder; // null = root
  Set<String> _selected = {};
  Timer? _poll;
  final List<_TransferJob> _jobs = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _refresh(silent: true));
  }

  @override
  void didUpdateWidget(covariant ClientDriveScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If GoRouter reuses the State across route switches (same widget
    // type, different filter) the file list would stay stale. Detect the
    // filter change and force a refetch — Trash needs include_deleted=true
    // on the wire, the others need it false.
    if (oldWidget.filter != widget.filter) {
      _files = [];
      _loading = true;
      _refresh();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool silent = false}) async {
    if (!silent) setState(() { _loading = true; _error = null; });
    final client = ref.read(relayClientProvider);
    final favs = ref.read(favoritesServiceProvider);
    try {
      // Trash view fetches soft-deleted entries; everything else fetches the
      // current folder (null = root).
      final res = await client.listFiles(
        includeDeleted: widget.filter == DriveFilter.trash,
        parent: widget.filter == DriveFilter.myDrive ? _currentFolder : null,
      );
      final stats = await client.stats();
      final favoriteIds = await favs.all();
      if (!mounted) return;
      setState(() {
        _files = res.files;
        _path = res.path;
        _stats = stats;
        _favorites = favoriteIds;
        _loading = false;
      });
    } on RelayException catch (e) {
      if (!silent && mounted) {
        setState(() {
          _loading = false;
          _error = _friendlyError(e);
        });
      }
    } catch (e) {
      if (!silent && mounted) {
        setState(() {
          _loading = false;
          _error = 'Network error: $e';
        });
      }
    }
  }

  String _friendlyError(RelayException e) {
    if (e.body.contains('host_offline')) return 'Your storage is offline. Open the Weeber app on your home computer.';
    if (e.body.contains('no_active_host')) return 'No host is set up yet. Open the Weeber app on your home computer.';
    return 'Could not reach storage (HTTP ${e.statusCode}).';
  }

  Future<void> _pickAndUpload() async {
    final picked = await FilePicker.platform.pickFiles(allowMultiple: true, withData: true);
    if (picked == null) return;
    final client = ref.read(relayClientProvider);
    for (final f in picked.files) {
      final bytes = f.bytes;
      if (bytes == null) continue;
      final mime = _guessMime(f.name);
      final job = _TransferJob(name: f.name, total: bytes.length, isUpload: true);
      setState(() => _jobs.add(job));
      try {
        await client.upload(
          name: f.name,
          mime: mime,
          bytes: bytes,
          parentId: _currentFolder,
          onProgress: (sent, total) {
            if (!mounted) return;
            setState(() => job.done = sent);
          },
        );
        job.status = _JobStatus.done;
      } catch (e) {
        job.status = _JobStatus.error;
        job.error = e.toString();
      }
      if (mounted) {
        setState(() {});
        // Auto-dismiss successful jobs only. Errored jobs stay visible
        // until the user taps them — otherwise the error flashes by.
        if (job.status == _JobStatus.done) {
          Future.delayed(const Duration(milliseconds: 1200), () {
            if (mounted) setState(() => _jobs.remove(job));
          });
        }
      }
    }
    await _refresh(silent: true);
  }

  Future<void> _download(RelayFile f) async {
    final client = ref.read(relayClientProvider);
    final job = _TransferJob(name: f.name, total: f.size, isUpload: false);
    setState(() => _jobs.add(job));
    try {
      final bytes = await client.downloadFile(
        id: f.id,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            job.done = received;
            if (total > 0) job.total = total;
          });
        },
      );
      await _saveBytes(f.name, bytes);
      job.status = _JobStatus.done;
    } catch (e) {
      job.status = _JobStatus.error;
      job.error = e.toString();
    }
    if (mounted) {
      setState(() {});
      if (job.status == _JobStatus.done) {
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (mounted) setState(() => _jobs.remove(job));
        });
      }
    }
  }

  Future<void> _saveBytes(String name, Uint8List bytes) async {
    if (Platform.isAndroid || Platform.isIOS) {
      // On mobile, drop into the OS share/save sheet via file_picker.
      final out = await FilePicker.platform.saveFile(
        dialogTitle: 'Save file',
        fileName: name,
        bytes: bytes,
      );
      if (out != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved.')));
      }
      return;
    }
    // Desktop client view: write to Downloads folder.
    final dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
    final outPath = p.join(dir.path, name);
    await File(outPath).writeAsBytes(bytes, flush: true);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved to $outPath')));
    }
  }

  Future<void> _confirmDelete(RelayFile f) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 18),
              decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2))),
          Text('Delete "${f.name}"?', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text('You can remove it from Weeber (it disappears on every device) or just hide it on this phone.',
              textAlign: TextAlign.center, style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey.shade700, height: 1.4)),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: () => Navigator.of(ctx).pop('host'),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete from Weeber (all devices)'),
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade600),
          ),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: () => Navigator.of(ctx).pop('local'), child: const Text('Just hide it on this phone')),
          const SizedBox(height: 6),
          TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Cancel')),
        ]),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'local') {
      // No persistent client-side hide list yet — refresh restores. Same UX
      // as the website "Just hide it from this page".
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Hidden from this view. Pull to refresh to restore.'),
      ));
      setState(() => _files.removeWhere((x) => x.id == f.id));
      return;
    }
    final client = ref.read(relayClientProvider);
    setState(() => _files.removeWhere((x) => x.id == f.id));
    try {
      await client.deleteFile(f.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
        await _refresh();
      }
    }
  }

  static String _guessMime(String name) {
    final ext = p.extension(name).toLowerCase();
    return switch (ext) {
      '.png' => 'image/png',
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.gif' => 'image/gif',
      '.webp' => 'image/webp',
      '.heic' => 'image/heic',
      '.mp4' => 'video/mp4',
      '.mov' => 'video/quicktime',
      '.mp3' => 'audio/mpeg',
      '.wav' => 'audio/wav',
      '.pdf' => 'application/pdf',
      '.doc' || '.docx' => 'application/msword',
      '.xls' || '.xlsx' => 'application/vnd.ms-excel',
      '.ppt' || '.pptx' => 'application/vnd.ms-powerpoint',
      '.txt' || '.md' => 'text/plain',
      '.json' => 'application/json',
      _ => 'application/octet-stream',
    };
  }

  List<RelayFile> _filteredFiles() {
    final out = switch (widget.filter) {
      DriveFilter.myDrive => _files,
      DriveFilter.recent => ([..._files]..sort((a, b) => b.createdAt.compareTo(a.createdAt))).take(50).toList(),
      DriveFilter.favorites => _files.where((f) => _favorites.contains(f.id)).toList(),
      DriveFilter.trash => _files,
    };
    // Folders always at top, then files, both alphabetical (Drive convention).
    final sorted = [...out]..sort((a, b) {
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return sorted;
  }

  Future<void> _newFolder() async {
    final controller = TextEditingController(text: 'Untitled folder');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(children: [Icon(Icons.create_new_folder_rounded), SizedBox(width: 8), Text('New folder')]),
        content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(hintText: 'Folder name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Create')),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      await ref.read(relayClientProvider).createFolder(name: name, parentId: _currentFolder);
      await _refresh(silent: true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not create folder: $e')));
    }
  }

  void _enterFolder(RelayFile folder) {
    setState(() {
      _currentFolder = folder.id;
      _selected = {};
    });
    _refresh(silent: false);
  }

  void _navigateTo(String? id) {
    setState(() {
      _currentFolder = id;
      _selected = {};
    });
    _refresh(silent: false);
  }

  void _toggleSelect(RelayFile f) {
    setState(() {
      if (_selected.contains(f.id)) {
        _selected.remove(f.id);
      } else {
        _selected.add(f.id);
      }
    });
  }

  Future<void> _bulkDelete() async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    setState(() {
      _files.removeWhere((f) => _selected.contains(f.id));
      _selected = {};
    });
    try {
      await ref.read(relayClientProvider).bulkAction(action: 'delete', ids: ids);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Bulk delete failed: $e')));
      await _refresh();
    }
  }

  Future<void> _bulkMove() async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final target = await _pickFolder(excludeIds: ids);
    if (target == null && !mounted) return;
    try {
      await ref.read(relayClientProvider).bulkAction(action: 'move', ids: ids, parentId: target ?? '');
      setState(() => _selected = {});
      await _refresh(silent: true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Move failed: $e')));
    }
  }

  /// Returns the picked folder id (null = root). Returns the literal
  /// string "__cancel__" via a non-null check to know if user cancelled.
  Future<String?> _pickFolder({required List<String> excludeIds}) async {
    String? browseId;
    final result = await showModalBottomSheet<_FolderPickResult>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _FolderPicker(
        excludeIds: excludeIds.toSet(),
        initialFolderId: browseId,
        onPick: (id) => Navigator.pop(ctx, _FolderPickResult(id)),
      ),
    );
    return result?.id;
  }

  String get _title => switch (widget.filter) {
        DriveFilter.myDrive => 'My Drive',
        DriveFilter.recent => 'Recent',
        DriveFilter.favorites => 'Starred',
        DriveFilter.trash => 'Trash',
      };

  String get _activeRoute => switch (widget.filter) {
        DriveFilter.myDrive => '/drive',
        DriveFilter.recent => '/drive/recent',
        DriveFilter.favorites => '/drive/favorites',
        DriveFilter.trash => '/drive/trash',
      };

  Future<void> _toggleFavorite(RelayFile f) async {
    await ref.read(favoritesServiceProvider).toggle(f.id);
    final favs = await ref.read(favoritesServiceProvider).all();
    if (mounted) setState(() => _favorites = favs);
  }

  Future<void> _restore(RelayFile f) async {
    try {
      await ref.read(relayClientProvider).restoreFile(f.id);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Restored "${f.name}"')));
      await _refresh(silent: true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Restore failed: $e')));
    }
  }

  Future<void> _hardDelete(RelayFile f) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete forever?'),
        content: Text('"${f.name}" will be permanently removed. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade600),
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(relayClientProvider).deleteFile(f.id, hard: true);
      if (mounted) setState(() => _files.removeWhere((x) => x.id == f.id));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hostRole = ref.watch(hostRoleProvider);
    final isDesktopClient = (Platform.isMacOS || Platform.isWindows || Platform.isLinux) && hostRole.role != HostRole.active;
    final visible = _filteredFiles();
    final showFolderTools = widget.filter == DriveFilter.myDrive;
    return AppShell(
      title: showFolderTools && _path.isNotEmpty ? _path.last.name : _title,
      activeRoute: _activeRoute,
      onCreateNew: _pickAndUpload,
      child: Stack(
        children: [
          RefreshIndicator(
            onRefresh: () => _refresh(),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              children: [
                if (_stats != null)
                  MobileStorageCard(
                    usedBytes: _stats!.usedBytes,
                    allocatedBytes: _stats!.allocatedBytes,
                    fileCount: _stats!.fileCount,
                  ),
                if (isDesktopClient)
                  _DesktopClientBanner(onTakeOver: () async {
                    final ok = await _confirmTakeOver(context);
                    if (!ok || !mounted) return;
                    await ref.read(hostLifecycleProvider).ensureRunning(forceTakeOver: true);
                    if (!mounted) return;
                    ref.read(hostRoleProvider.notifier).setActive();
                    if (context.mounted) context.go('/drive');
                  }),
                if (showFolderTools) _BreadcrumbBar(path: _path, onHome: () => _navigateTo(null), onJump: _navigateTo, onNewFolder: _newFolder),
                if (!showFolderTools) _SectionHeader(title: _title, count: visible.length, hint: _hintFor(widget.filter)),
                if (_loading && _files.isEmpty) const Padding(
                  padding: EdgeInsets.symmetric(vertical: 80), child: Center(child: CircularProgressIndicator())),
                if (_error != null) _ErrorBanner(message: _error!, onRetry: () => _refresh()),
                if (!_loading && visible.isEmpty && _error == null) _EmptyState(filter: widget.filter),
                for (final f in visible) _FileRow(
                  file: f,
                  isFavorite: _favorites.contains(f.id),
                  isSelected: _selected.contains(f.id),
                  filter: widget.filter,
                  onTap: () {
                    if (_selected.isNotEmpty) { _toggleSelect(f); return; }
                    if (f.isFolder) { _enterFolder(f); } else { _download(f); }
                  },
                  onLongPress: () => _toggleSelect(f),
                  onSelectToggle: () => _toggleSelect(f),
                  onDownload: () => _download(f),
                  onDelete: () => _confirmDelete(f),
                  onFavorite: () => _toggleFavorite(f),
                  onRestore: () => _restore(f),
                  onHardDelete: () => _hardDelete(f),
                ),
                const SizedBox(height: 96),
              ],
            ),
          ),
          if (_jobs.isNotEmpty) Positioned(
            left: 12, right: 12, bottom: 80,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final j in _jobs) _ProgressTile(
                job: j,
                onDismiss: j.status == _JobStatus.error ? () => setState(() => _jobs.remove(j)) : null,
              ),
            ]),
          ),
          if (_selected.isNotEmpty) Positioned(
            left: 12, right: 12, bottom: 12,
            child: _BulkBar(
              count: _selected.length,
              onClear: () => setState(() => _selected = {}),
              onMove: _bulkMove,
              onDelete: _bulkDelete,
            ),
          ),
        ],
      ),
      floatingActionButton: widget.filter == DriveFilter.trash
          ? null
          : FloatingActionButton.extended(
              onPressed: _pickAndUpload,
              backgroundColor: AppTheme.accent,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: const Text('Upload'),
            ),
    );
  }

  String? _hintFor(DriveFilter f) => switch (f) {
        DriveFilter.recent => 'Most recently uploaded files first.',
        DriveFilter.favorites => 'Tap the star on any file to add it here. Stars are saved on this device.',
        DriveFilter.trash => 'Files in trash can be restored. Use "Delete forever" to free up storage.',
        DriveFilter.myDrive => null,
      };

  Future<bool> _confirmTakeOver(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Switch host to this Mac?'),
        content: const Text(
          "Files added on the other computer will stay on that computer — they won't move "
          "to this Mac automatically. Only one host at a time.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Yes, switch')),
        ],
      ),
    );
    return result == true;
  }
}

class _FolderPickResult {
  _FolderPickResult(this.id);
  final String? id;
}

enum _JobStatus { running, done, error }

class _TransferJob {
  _TransferJob({required this.name, required this.total, required this.isUpload});
  final String name;
  int total;
  int done = 0;
  final bool isUpload;
  _JobStatus status = _JobStatus.running;
  String? error;
}

class _ProgressTile extends StatelessWidget {
  const _ProgressTile({required this.job, this.onDismiss});
  final _TransferJob job;
  final VoidCallback? onDismiss;
  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    final pct = job.total > 0 ? (job.done / job.total).clamp(0.0, 1.0) : (job.status == _JobStatus.done ? 1.0 : 0.0);
    return InkWell(
      onTap: onDismiss,
      child: Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 12, offset: const Offset(0, 2))],
        border: Border.all(color: c.border),
      ),
      child: Row(children: [
        Container(width: 28, height: 28, alignment: Alignment.center,
          decoration: BoxDecoration(color: AppTheme.accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
          child: Icon(job.isUpload ? Icons.upload_rounded : Icons.download_rounded, size: 14, color: AppTheme.accent),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(job.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w500)),
          const SizedBox(height: 2),
          Text(
            job.status == _JobStatus.error ? 'Error: ${job.error ?? 'failed'}'
              : job.status == _JobStatus.done ? 'Complete'
              : '${formatBytes(job.done)} / ${formatBytes(job.total)} · ${(pct * 100).toStringAsFixed(0)}%',
            style: GoogleFonts.poppins(fontSize: 10, color: c.textMuted),
          ),
          const SizedBox(height: 4),
          ClipRRect(borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: pct, minHeight: 3,
              backgroundColor: c.border,
              valueColor: AlwaysStoppedAnimation(job.status == _JobStatus.error ? Colors.red : AppTheme.accent),
            ),
          ),
        ])),
        if (onDismiss != null) const Icon(Icons.close, size: 16, color: Colors.grey),
      ]),
    ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.file,
    required this.isFavorite,
    required this.isSelected,
    required this.filter,
    required this.onTap,
    required this.onLongPress,
    required this.onSelectToggle,
    required this.onDownload,
    required this.onDelete,
    required this.onFavorite,
    required this.onRestore,
    required this.onHardDelete,
  });
  final RelayFile file;
  final bool isFavorite;
  final bool isSelected;
  final DriveFilter filter;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onSelectToggle;
  final VoidCallback onDownload;
  final VoidCallback onDelete;
  final VoidCallback onFavorite;
  final VoidCallback onRestore;
  final VoidCallback onHardDelete;

  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    final isTrash = filter == DriveFilter.trash;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.accent.withValues(alpha: 0.08) : null,
          border: Border(bottom: BorderSide(color: c.border)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(children: [
          if (file.isFolder)
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(10)),
              alignment: Alignment.center,
              child: const Icon(Icons.folder_rounded, size: 22, color: Color(0xFFD97706)),
            )
          else
            FilePreview(mime: file.mime, name: file.name, size: 44),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w500, color: c.textPrimary))),
              if (isFavorite && !isTrash && !file.isFolder) ...[
                const SizedBox(width: 4),
                const Icon(Icons.star_rounded, size: 14, color: Color(0xFFF59E0B)),
              ],
            ]),
            const SizedBox(height: 3),
            Text(file.isFolder ? 'Folder · ${_fmt(file.createdAt)}' : '${formatBytes(file.size)} · ${_fmt(file.createdAt)}',
                style: GoogleFonts.poppins(fontSize: 11, color: c.textMuted)),
          ])),
          if (isSelected)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.check_circle_rounded, color: AppTheme.accent),
            ),
          // Single ⋯ menu — Google-Drive-style. Different actions in Trash vs other views.
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 22),
            tooltip: 'More',
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            onSelected: (v) {
              switch (v) {
                case 'download': onDownload(); break;
                case 'fav': onFavorite(); break;
                case 'delete': onDelete(); break;
                case 'restore': onRestore(); break;
                case 'forever': onHardDelete(); break;
              }
            },
            itemBuilder: (_) => isTrash ? [
              const PopupMenuItem(value: 'restore', child: ListTile(
                leading: Icon(Icons.restore_rounded), title: Text('Restore'), dense: true)),
              PopupMenuItem(value: 'forever', child: ListTile(
                leading: Icon(Icons.delete_forever_rounded, color: Colors.red.shade600),
                title: Text('Delete forever', style: TextStyle(color: Colors.red.shade600)), dense: true)),
            ] : [
              const PopupMenuItem(value: 'download', child: ListTile(
                leading: Icon(Icons.download_rounded), title: Text('Download'), dense: true)),
              PopupMenuItem(value: 'fav', child: ListTile(
                leading: Icon(isFavorite ? Icons.star_rounded : Icons.star_outline_rounded,
                    color: isFavorite ? const Color(0xFFF59E0B) : null),
                title: Text(isFavorite ? 'Remove from Starred' : 'Add to Starred'), dense: true)),
              PopupMenuItem(value: 'delete', child: ListTile(
                leading: Icon(Icons.delete_outline, color: Colors.red.shade600),
                title: Text('Delete', style: TextStyle(color: Colors.red.shade600)), dense: true)),
            ],
          ),
        ]),
      ),
    );
  }

  static const _months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  static String _fmt(int unix) {
    if (unix == 0) return 'just now';
    final d = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
    return '${_months[d.month - 1]} ${d.day}, ${d.year}';
  }
}

class _BreadcrumbBar extends StatelessWidget {
  const _BreadcrumbBar({required this.path, required this.onHome, required this.onJump, required this.onNewFolder});
  final List<RelayCrumb> path;
  final void Function() onHome;
  final void Function(String id) onJump;
  final VoidCallback onNewFolder;
  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    final crumbWidgets = <Widget>[
      InkWell(
        onTap: onHome,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.home_rounded, size: 16, color: AppTheme.accent),
            const SizedBox(width: 4),
            Text('My files', style: GoogleFonts.poppins(fontSize: 13, color: path.isEmpty ? c.textPrimary : c.textMuted, fontWeight: path.isEmpty ? FontWeight.w600 : FontWeight.w400)),
          ]),
        ),
      ),
    ];
    for (var i = 0; i < path.length; i++) {
      crumbWidgets.add(const Icon(Icons.chevron_right_rounded, size: 16));
      final isLast = i == path.length - 1;
      crumbWidgets.add(InkWell(
        onTap: isLast ? null : () => onJump(path[i].id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Text(path[i].name,
              style: GoogleFonts.poppins(fontSize: 13, color: isLast ? c.textPrimary : c.textMuted, fontWeight: isLast ? FontWeight.w600 : FontWeight.w400)),
        ),
      ));
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
      child: Row(children: [
        Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: crumbWidgets))),
        IconButton(
          tooltip: 'New folder',
          onPressed: onNewFolder,
          icon: const Icon(Icons.create_new_folder_outlined),
        ),
      ]),
    );
  }
}

class _BulkBar extends StatelessWidget {
  const _BulkBar({required this.count, required this.onClear, required this.onMove, required this.onDelete});
  final int count;
  final VoidCallback onClear;
  final VoidCallback onMove;
  final VoidCallback onDelete;
  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 16, offset: const Offset(0, 4))],
        border: Border.all(color: c.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(onPressed: onClear, icon: const Icon(Icons.close_rounded, size: 20)),
        Text('$count selected', style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(width: 12),
        TextButton.icon(onPressed: onMove, icon: const Icon(Icons.drive_file_move_outline, size: 18), label: const Text('Move')),
        TextButton.icon(onPressed: onDelete, icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red), label: const Text('Delete', style: TextStyle(color: Colors.red))),
      ]),
    );
  }
}

class _FolderPicker extends ConsumerStatefulWidget {
  const _FolderPicker({required this.excludeIds, required this.onPick, this.initialFolderId});
  final Set<String> excludeIds;
  final String? initialFolderId;
  final void Function(String? folderId) onPick;
  @override
  ConsumerState<_FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends ConsumerState<_FolderPicker> {
  String? _browseId;
  List<RelayCrumb> _path = [];
  List<RelayFile> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _browseId = widget.initialFolderId;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await ref.read(relayClientProvider).listFiles(parent: _browseId);
      if (!mounted) return;
      setState(() {
        _items = res.files.where((f) => f.isFolder).toList();
        _path = res.path;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.9,
      minChildSize: 0.4,
      expand: false,
      builder: (_, controller) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
              alignment: Alignment.center),
          Text('Move to folder…', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          _BreadcrumbBar(
            path: _path,
            onHome: () { setState(() => _browseId = null); _load(); },
            onJump: (id) { setState(() => _browseId = id); _load(); },
            onNewFolder: () {},
          ),
          Expanded(child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _items.isEmpty
                  ? Center(child: Text('No subfolders here.', style: GoogleFonts.poppins(fontSize: 12, color: c.textMuted)))
                  : ListView(controller: controller, children: [
                      for (final f in _items)
                        ListTile(
                          leading: Container(
                            width: 36, height: 36,
                            decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(8)),
                            child: const Icon(Icons.folder_rounded, color: Color(0xFFD97706), size: 18),
                          ),
                          title: Text(f.name, style: GoogleFonts.poppins(fontSize: 13)),
                          enabled: !widget.excludeIds.contains(f.id),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () { setState(() => _browseId = f.id); _load(); },
                        ),
                    ])),
          const SizedBox(height: 8),
          Row(children: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            const Spacer(),
            FilledButton.icon(
              onPressed: () => widget.onPick(_browseId),
              icon: const Icon(Icons.drive_file_move_outline),
              label: const Text('Move here'),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.count, this.hint});
  final String title;
  final int count;
  final String? hint;
  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(title, style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w700, color: c.textPrimary)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: AppTheme.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(99),
            ),
            child: Text('$count',
                style: GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.accent)),
          ),
        ]),
        if (hint != null) ...[
          const SizedBox(height: 4),
          Text(hint!, style: GoogleFonts.poppins(fontSize: 11.5, color: c.textMuted)),
        ],
      ]),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.filter});
  final DriveFilter filter;
  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    final (icon, title, body) = switch (filter) {
      DriveFilter.myDrive => (Icons.cloud_upload_outlined, 'No files yet', 'Tap Upload to add your first file.'),
      DriveFilter.recent => (Icons.access_time_rounded, 'Nothing recent', "Files you upload will show up here."),
      DriveFilter.favorites => (Icons.star_outline_rounded, 'No starred files', 'Tap the ⋯ menu on any file → Add to Starred. Stars are saved on this device.'),
      DriveFilter.trash => (Icons.delete_outline_rounded, 'Trash is empty', "Deleted files appear here. They aren't gone forever until you choose Delete forever."),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 24),
      child: Column(children: [
        Container(
          width: 80, height: 80,
          decoration: BoxDecoration(color: AppTheme.accent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
          child: Icon(icon, size: 40, color: AppTheme.accent),
        ),
        const SizedBox(height: 16),
        Text(title, style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w600, color: c.textPrimary)),
        const SizedBox(height: 6),
        Text(body, textAlign: TextAlign.center,
            style: GoogleFonts.poppins(fontSize: 12, color: c.textMuted, height: 1.4)),
      ]),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.amber.shade50, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.amber.shade200),
      ),
      child: Row(children: [
        Icon(Icons.cloud_off_rounded, color: Colors.amber.shade800),
        const SizedBox(width: 10),
        Expanded(child: Text(message, style: GoogleFonts.poppins(fontSize: 12, color: Colors.amber.shade900))),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ]),
    );
  }
}

class _DesktopClientBanner extends StatelessWidget {
  const _DesktopClientBanner({required this.onTakeOver});
  final VoidCallback onTakeOver;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Colors.amber.shade50, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.amber.shade200),
      ),
      child: Row(children: [
        Icon(Icons.computer_rounded, color: Colors.amber.shade800, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text('Your files live on another computer. This Mac is acting as a client.',
              style: GoogleFonts.poppins(fontSize: 12, color: Colors.amber.shade900)),
        ),
        TextButton(onPressed: onTakeOver, child: const Text('Host here')),
      ]),
    );
  }
}
