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
import '../../services/host_lifecycle.dart';
import '../../services/relay_client.dart';
import '../../state/host_role.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/byte_size.dart';
import '../../widgets/file_preview.dart';
import '../../widgets/mobile_storage_card.dart';

/// Client drive — used by mobile (iOS/Android) and any desktop that isn't
/// the active host. Talks to the VPS relay (no UPnP / port forward
/// required). Auto-polls every 4s so cross-device uploads appear.
class ClientDriveScreen extends ConsumerStatefulWidget {
  const ClientDriveScreen({super.key});
  @override
  ConsumerState<ClientDriveScreen> createState() => _ClientDriveScreenState();
}

class _ClientDriveScreenState extends ConsumerState<ClientDriveScreen> {
  bool _loading = true;
  String? _error;
  List<RelayFile> _files = [];
  RelayStats? _stats;
  Timer? _poll;
  final List<_TransferJob> _jobs = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _refresh(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool silent = false}) async {
    if (!silent) setState(() { _loading = true; _error = null; });
    final client = ref.read(relayClientProvider);
    try {
      final files = await client.listFiles();
      final stats = await client.stats();
      if (!mounted) return;
      setState(() { _files = files; _stats = stats; _loading = false; });
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

  @override
  Widget build(BuildContext context) {
    final hostRole = ref.watch(hostRoleProvider);
    final isDesktopClient = (Platform.isMacOS || Platform.isWindows || Platform.isLinux) && hostRole.role != HostRole.active;
    return AppShell(
      title: 'My Drive',
      activeRoute: '/drive',
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
                if (_loading && _files.isEmpty) const Padding(
                  padding: EdgeInsets.symmetric(vertical: 80), child: Center(child: CircularProgressIndicator())),
                if (_error != null) _ErrorBanner(message: _error!, onRetry: () => _refresh()),
                if (!_loading && _files.isEmpty && _error == null) const _EmptyState(),
                for (final f in _files) _FileRow(
                  file: f,
                  onDownload: () => _download(f),
                  onDelete: () => _confirmDelete(f),
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
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _pickAndUpload,
        backgroundColor: AppTheme.accent,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

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
  const _FileRow({required this.file, required this.onDownload, required this.onDelete});
  final RelayFile file;
  final VoidCallback onDownload;
  final VoidCallback onDelete;
  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    return Container(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(children: [
        FilePreview(mime: file.mime, name: file.name, size: 38),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w500, color: c.textPrimary)),
          const SizedBox(height: 2),
          Text('${formatBytes(file.size)} · ${_fmt(file.createdAt)}',
              style: GoogleFonts.poppins(fontSize: 10.5, color: c.textMuted)),
        ])),
        IconButton(icon: const Icon(Icons.download_outlined, size: 20), onPressed: onDownload, tooltip: 'Download'),
        IconButton(icon: Icon(Icons.delete_outline, size: 20, color: Colors.red.shade400), onPressed: onDelete, tooltip: 'Delete'),
      ]),
    );
  }
  static const _months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  static String _fmt(int unix) {
    if (unix == 0) return 'just now';
    final d = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
    return '${_months[d.month - 1]} ${d.day}, ${d.year}';
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    final c = context.weeberColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 24),
      child: Column(children: [
        Container(
          width: 80, height: 80,
          decoration: BoxDecoration(color: AppTheme.accent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
          child: const Icon(Icons.cloud_upload_outlined, size: 40, color: AppTheme.accent),
        ),
        const SizedBox(height: 16),
        Text('No files yet', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w600, color: c.textPrimary)),
        const SizedBox(height: 4),
        Text('Tap the + button to upload your first file.',
            textAlign: TextAlign.center, style: GoogleFonts.poppins(fontSize: 12, color: c.textMuted)),
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
