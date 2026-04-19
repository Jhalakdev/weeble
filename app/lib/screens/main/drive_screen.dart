import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import '../../services/file_index.dart';
import '../../services/storage_allocator.dart';
import '../../state/auth.dart';
import '../../state/config.dart';
import '../../state/host_runtime.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/byte_size.dart';
import '../../widgets/delete_confirm_dialog.dart';
import '../../widgets/share_dialog.dart';
import '../../widgets/storage_line_chart.dart';
import '../../widgets/upgrade_banner.dart';

/// Desktop dashboard. Shows real files from the host's local index.
/// No placeholder / template content — empty state when there's nothing to show.
class DriveScreen extends ConsumerStatefulWidget {
  const DriveScreen({super.key});
  @override
  ConsumerState<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends ConsumerState<DriveScreen> {
  bool _dragging = false;
  List<FileEntry> _files = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    final runtime = await ref.read(hostRuntimeProvider.future);
    if (runtime == null) return;
    final files = await runtime.index.list();
    if (!mounted) return;
    setState(() { _files = files; });
  }

  Future<void> _pickAndUpload() async {
    final res = await FilePicker.platform.pickFiles(allowMultiple: true, withData: false);
    if (res == null) return;
    final paths = res.files.where((f) => f.path != null).map((f) => f.path!).toList();
    await _uploadPaths(paths);
  }

  Future<void> _uploadPaths(List<String> paths) async {
    final runtime = await ref.read(hostRuntimeProvider.future);
    if (runtime == null) return;
    final cfg = ref.read(appConfigProvider);
    final allocated = cfg.allocatedBytes ?? 0;
    int running = await runtime.index.totalSize();

    for (final path in paths) {
      final file = File(path);
      if (!await file.exists()) continue;
      final size = await file.length();
      if (running + size > allocated) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Not enough space — ${formatBytes(allocated - running)} free')),
        );
        return;
      }
      final bytes = await file.readAsBytes();
      final id = _ulid();
      final name = p.basename(path);
      final mime = _guessMime(name);
      await runtime.storage.write(id, bytes);
      await runtime.index.insert(FileEntry(
        id: id, name: name, parentId: null, size: size, mime: mime,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ));
      if (cfg.storagePath != null) {
        await StorageAllocator.resize(rootPath: cfg.storagePath!, newBytes: allocated);
      }
      running += size;
    }
    await _refresh();
  }

  Future<void> _deleteFile(FileEntry entry) async {
    final scope = await DeleteConfirmDialog.show(context, fileName: entry.name);
    if (scope == DeleteScope.cancelled) return;
    final runtime = await ref.read(hostRuntimeProvider.future);
    if (runtime == null) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await runtime.index.softDelete(entry.id, at: now);
    await runtime.storage.delete(entry.id);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final accountId = ref.watch(authProvider).accountId ?? 'friend';
    final canDrop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;

    return AppShell(
      title: 'My Drive',
      activeRoute: '/drive',
      onCreateNew: _pickAndUpload,
      child: LayoutBuilder(builder: (context, cons) {
        final body = SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _HeaderRow(name: _shortName(accountId), fileCount: _files.length, onUpload: _pickAndUpload),
              const SizedBox(height: 24),
              if (_files.isEmpty)
                _DriveEmptyState(onUpload: _pickAndUpload)
              else ...[
                _FilesTable(files: _files, onDelete: _deleteFile, onShare: (f) => ShareDialog.show(context, f)),
                const SizedBox(height: 24),
                const _BottomRow(),
              ],
              const SizedBox(height: 32),
            ],
          ),
        );
        if (!canDrop) return body;
        return DropTarget(
          onDragEntered: (_) => setState(() => _dragging = true),
          onDragExited: (_) => setState(() => _dragging = false),
          onDragDone: (d) async {
            setState(() => _dragging = false);
            await _uploadPaths(d.files.map((e) => e.path).toList());
          },
          child: Stack(children: [
            body,
            if (_dragging) IgnorePointer(child: Container(
              color: AppTheme.accent.withValues(alpha: 0.08),
              alignment: Alignment.center,
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: context.weeberColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.accent, width: 2),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.cloud_upload_rounded, color: AppTheme.accent),
                  const SizedBox(width: 8),
                  Text('Drop to upload', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
                ]),
              ),
            )),
          ]),
        );
      }),
    );
  }

  static String _shortName(String id) {
    if (id.contains('@')) return id.split('@').first;
    return id.length > 12 ? id.substring(0, 6) : id;
  }

  static String _guessMime(String name) {
    final ext = p.extension(name).toLowerCase();
    return switch (ext) {
      '.png' => 'image/png', '.jpg' || '.jpeg' => 'image/jpeg',
      '.gif' => 'image/gif', '.webp' => 'image/webp',
      '.mp4' => 'video/mp4', '.mp3' => 'audio/mpeg',
      '.pdf' => 'application/pdf',
      '.doc' || '.docx' => 'application/msword',
      '.xls' || '.xlsx' => 'application/vnd.ms-excel',
      '.ppt' || '.pptx' => 'application/vnd.ms-powerpoint',
      '.txt' || '.md' => 'text/plain', '.json' => 'application/json',
      _ => 'application/octet-stream',
    };
  }

  static int _randCtr = 0;
  static String _ulid() {
    final t = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final r = (DateTime.now().microsecondsSinceEpoch & 0xfffffff).toRadixString(36);
    return '$t-$r-${(++_randCtr).toRadixString(36).padLeft(4, "0")}';
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.name, required this.fileCount, required this.onUpload});
  final String name;
  final int fileCount;
  final VoidCallback onUpload;

  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: c.surface, borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Welcome, $name', style: GoogleFonts.poppins(fontSize: 22, fontWeight: FontWeight.w700, color: c.textPrimary)),
                const SizedBox(height: 6),
                Text(
                  fileCount == 0
                      ? 'Your drive is ready. Upload your first file to get started.'
                      : 'You have $fileCount file${fileCount == 1 ? '' : 's'} in your drive.',
                  style: GoogleFonts.poppins(fontSize: 13, color: c.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          FilledButton.icon(
            onPressed: onUpload,
            icon: const Icon(Icons.cloud_upload_rounded, size: 18),
            label: const Text('Upload files'),
          ),
        ],
      ),
    );
  }
}

class _DriveEmptyState extends StatelessWidget {
  const _DriveEmptyState({required this.onUpload});
  final VoidCallback onUpload;
  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 56, horizontal: 24),
      decoration: BoxDecoration(
        color: c.surface, borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          Container(
            width: 88, height: 88,
            decoration: BoxDecoration(
              color: AppTheme.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(Icons.cloud_upload_outlined, size: 44, color: AppTheme.accent),
          ),
          const SizedBox(height: 20),
          Text('Your drive is empty',
              style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w600, color: c.textPrimary)),
          const SizedBox(height: 6),
          Text(
            'Drag files anywhere on this screen to upload,\nor click the button below.',
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(fontSize: 13, color: c.textMuted, height: 1.5),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onUpload,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Upload files'),
          ),
          const SizedBox(height: 12),
          Text('Files are encrypted on disk. Only your paired devices can read them.',
              style: GoogleFonts.poppins(fontSize: 11, color: c.textMuted)),
        ],
      ),
    );
  }
}

class _FilesTable extends StatelessWidget {
  const _FilesTable({required this.files, required this.onDelete, required this.onShare});
  final List<FileEntry> files;
  final void Function(FileEntry) onDelete;
  final void Function(FileEntry) onShare;
  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    return Container(
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: c.border)),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text('Files', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: c.textPrimary)),
            const Spacer(),
            Text('${files.length} item${files.length == 1 ? '' : 's'}',
                style: GoogleFonts.poppins(fontSize: 12, color: c.textMuted)),
          ]),
          const SizedBox(height: 12),
          _FilesHeader(),
          const Divider(height: 1),
          for (final f in files) _FilesRow(file: f, onDelete: () => onDelete(f), onShare: () => onShare(f)),
        ],
      ),
    );
  }
}

class _FilesHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    final s = GoogleFonts.poppins(fontSize: 11, color: c.textMuted, fontWeight: FontWeight.w500);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(children: [
        Expanded(flex: 5, child: Text('Name', style: s)),
        Expanded(flex: 3, child: Text('Uploaded', style: s)),
        Expanded(flex: 2, child: Text('Size', style: s)),
        const SizedBox(width: 96),
      ]),
    );
  }
}

class _FilesRow extends StatelessWidget {
  const _FilesRow({required this.file, required this.onDelete, required this.onShare});
  final FileEntry file;
  final VoidCallback onDelete;
  final VoidCallback onShare;
  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    return InkWell(
      onTap: () {},
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(children: [
          Expanded(
            flex: 5,
            child: Row(children: [
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(color: AppTheme.accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                alignment: Alignment.center,
                child: Icon(_iconFor(file.mime), size: 16, color: AppTheme.accent),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.poppins(fontSize: 13, color: c.textPrimary))),
            ]),
          ),
          Expanded(flex: 3, child: Text(_fmt(file.createdAt), style: GoogleFonts.poppins(fontSize: 12, color: c.textMuted))),
          Expanded(flex: 2, child: Text(formatBytes(file.size), style: GoogleFonts.poppins(fontSize: 12, color: c.textMuted))),
          IconButton(icon: const Icon(Icons.link, size: 16), tooltip: 'Share link', onPressed: onShare),
          IconButton(icon: const Icon(Icons.delete_outline, size: 16), tooltip: 'Delete', onPressed: onDelete),
        ]),
      ),
    );
  }

  IconData _iconFor(String mime) {
    if (mime.startsWith('image/')) return Icons.image_outlined;
    if (mime.startsWith('video/')) return Icons.movie_outlined;
    if (mime.startsWith('audio/')) return Icons.audio_file_outlined;
    if (mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
    if (mime.startsWith('text/')) return Icons.description_outlined;
    return Icons.insert_drive_file_outlined;
  }

  static const _months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  String _fmt(int unix) {
    final d = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
    return '${_months[d.month - 1]} ${d.day.toString().padLeft(2, '0')}, ${d.year}';
  }
}

class _BottomRow extends StatelessWidget {
  const _BottomRow();
  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    return LayoutBuilder(builder: (context, cn) {
      final narrow = cn.maxWidth < 860;
      final storage = Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: c.border)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Storage over time', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: c.textPrimary)),
            const SizedBox(height: 10),
            const SizedBox(height: 160, child: StorageLineChart()),
          ],
        ),
      );
      const banner = UpgradeBanner();
      if (narrow) return const Column(children: [banner, SizedBox(height: 16)]);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Expanded(flex: 4, child: banner),
          const SizedBox(width: 16),
          Expanded(flex: 7, child: storage),
        ],
      );
    });
  }
}
