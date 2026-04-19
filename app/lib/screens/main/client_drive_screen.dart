import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import '../../api/client.dart';
import '../../services/host_client.dart';
import '../../state/auth.dart';
import '../../widgets/byte_size.dart';

/// Phone / client-side drive screen. Looks up the account's active host on
/// the VPS, connects directly to it over HTTPS (with cert pinning), lists
/// files, and lets the user download them.
class ClientDriveScreen extends ConsumerStatefulWidget {
  const ClientDriveScreen({super.key});
  @override
  ConsumerState<ClientDriveScreen> createState() => _ClientDriveScreenState();
}

class _ClientDriveScreenState extends ConsumerState<ClientDriveScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _files = [];
  String? _hostName;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final token = ref.read(authProvider).token;
    if (token == null) {
      setState(() {
        _loading = false;
        _error = 'Not signed in.';
      });
      return;
    }
    try {
      final res = await ref.read(hostClientProvider).listFiles(token: token);
      if (!mounted) return;
      setState(() {
        _files = res.files;
        _loading = false;
      });
    } on ApiException catch (e) {
      setState(() {
        _loading = false;
        _error = e.code == 'no_active_host' || e.code == 'host_offline'
            ? 'Your storage is offline. Open Weeber on your home computer.'
            : 'Could not reach storage: ${e.code}';
      });
    } on HostClientException catch (e) {
      setState(() {
        _loading = false;
        _error = 'Storage refused the connection (${e.statusCode}).';
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Network error: $e';
      });
    }
  }

  Future<void> _download(Map<String, dynamic> file) async {
    final token = ref.read(authProvider).token;
    if (token == null) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text('Downloading ${file['name']}…')));
    try {
      final bytes = await ref.read(hostClientProvider).downloadFile(
            token: token,
            hostDeviceId: '',
            fileId: file['id'] as String,
          );
      // Pick a save location.
      String? outDir;
      if (Platform.isAndroid || Platform.isIOS) {
        // On mobile, file_picker.saveFile is the right path.
        final out = await FilePicker.platform.saveFile(
          dialogTitle: 'Save file',
          fileName: file['name'] as String,
          bytes: Uint8List.fromList(bytes),
        );
        if (out == null) return; // user cancelled
        if (!mounted) return;
        messenger.showSnackBar(SnackBar(content: Text('Saved.')));
        return;
      } else {
        outDir = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Pick folder to save to');
        if (outDir == null) return;
        final outPath = p.join(outDir, file['name'] as String);
        await File(outPath).writeAsBytes(bytes, flush: true);
        if (!mounted) return;
        messenger.showSnackBar(SnackBar(content: Text('Saved to $outPath')));
      }
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Download failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_hostName ?? 'My files'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loading ? null : _refresh),
          IconButton(
            icon: const Icon(Icons.devices),
            onPressed: () => context.push('/devices'),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(authProvider.notifier).logout(),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _OfflineState(error: _error!, onRetry: _refresh)
              : _files.isEmpty
                  ? const _EmptyState()
                  : ListView.separated(
                      itemCount: _files.length,
                      separatorBuilder: (_, __) => Divider(height: 1, color: Colors.grey.shade200),
                      itemBuilder: (_, i) {
                        final f = _files[i];
                        return ListTile(
                          leading: Icon(_iconFor(f['mime'] as String? ?? '')),
                          title: Text(f['name'] as String),
                          subtitle: Text('${formatBytes(f['size'] as int? ?? 0)}'),
                          trailing: IconButton(
                            icon: const Icon(Icons.download_outlined),
                            onPressed: () => _download(f),
                          ),
                        );
                      },
                    ),
    );
  }

  IconData _iconFor(String mime) {
    if (mime.startsWith('image/')) return Icons.image_outlined;
    if (mime.startsWith('video/')) return Icons.movie_outlined;
    if (mime.startsWith('audio/')) return Icons.audio_file_outlined;
    if (mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
    return Icons.insert_drive_file_outlined;
  }
}

class _OfflineState extends StatelessWidget {
  const _OfflineState({required this.error, required this.onRetry});
  final String error;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 56, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(error, textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade700)),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open, size: 56, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            const Text('No files yet — upload from your computer to see them here.', textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

