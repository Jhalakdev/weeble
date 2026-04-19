import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../services/disk_space.dart';
import '../../services/storage_allocator.dart';
import '../../state/config.dart';
import '../../widgets/byte_size.dart';

class StorageScreen extends ConsumerStatefulWidget {
  const StorageScreen({super.key});
  @override
  ConsumerState<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends ConsumerState<StorageScreen> {
  String? _path;
  int _gb = 20;
  int? _freeBytes;
  bool _freeLoading = true;
  String? _freeError;
  bool _busy = false;
  String? _error;

  static const _safetyBytes = 10 * 1024 * 1024 * 1024; // 10 GB reserved for OS
  static const _minGb = 5;

  int get _freeGb => (_freeBytes == null) ? 0 : _freeBytes! ~/ (1024 * 1024 * 1024);

  int get _maxGb {
    if (_freeBytes == null) return _minGb;
    final usable = _freeBytes! - _safetyBytes;
    if (usable <= 0) return _minGb;
    return (usable ~/ (1024 * 1024 * 1024)).clamp(_minGb, 20 * 1024);
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final dir = await getApplicationSupportDirectory();
    setState(() => _path = p.join(dir.path, 'storage'));
    await _refreshFreeSpace();
  }

  Future<void> _refreshFreeSpace() async {
    if (_path == null) return;
    setState(() { _freeLoading = true; _freeError = null; });
    try {
      final bytes = await DiskSpace.freeBytes(_path!);
      if (!mounted) return;
      setState(() {
        _freeBytes = bytes;
        _freeLoading = false;
        if (_gb > _maxGb) _gb = _maxGb;
        if (_gb < _minGb) _gb = _minGb;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _freeBytes = null;
        _freeLoading = false;
        _freeError = 'Could not read disk free space: $e';
      });
    }
  }

  Future<void> _pickPath() async {
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose where to store your Weeber files',
    );
    if (picked != null) {
      setState(() => _path = p.join(picked, 'Weeber'));
      await _refreshFreeSpace();
    }
  }

  bool get _canCreate {
    if (_busy || _path == null) return false;
    if (_freeBytes == null) return false;
    if (_gb < _minGb || _gb > _maxGb) return false;
    return true;
  }

  Future<void> _create() async {
    if (!_canCreate) return;
    setState(() { _busy = true; _error = null; });
    try {
      final bytes = _gb * 1024 * 1024 * 1024;
      // Re-check against live disk state — other apps may have written since.
      final liveFree = await DiskSpace.freeBytes(_path!);
      if (liveFree - _safetyBytes < bytes) {
        setState(() {
          _error = 'Not enough free disk space now. Only ${formatBytes(liveFree - _safetyBytes)} can be allocated.';
          _freeBytes = liveFree;
          if (_gb > _maxGb) _gb = _maxGb;
          _busy = false;
        });
        return;
      }
      await StorageAllocator.initialize(rootPath: _path!, bytes: bytes);
      await ref.read(appConfigProvider.notifier).update((c) => c.copyWith(
            storagePath: _path,
            allocatedBytes: bytes,
          ));
      if (mounted) context.go('/onboarding/encryption');
    } on FileSystemException catch (e) {
      setState(() => _error = 'Could not create storage: ${e.message}');
    } catch (e) {
      setState(() => _error = 'Could not create storage: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final quickPicks = [5, 10, 20, 50, 100, 250, 500, 1024]
        .where((g) => g <= _maxGb)
        .toList();

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Allocate storage',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text(
                  'Weeber will reserve this much disk space on your computer. You can resize later — never more than your drive has free.',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 15, height: 1.4),
                ),
                const SizedBox(height: 32),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Location', style: TextStyle(fontSize: 13, color: Colors.grey)),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(child: Text(_path ?? '…', style: const TextStyle(fontFamily: 'monospace'))),
                          TextButton(onPressed: _busy ? null : _pickPath, child: const Text('Change')),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                if (_freeLoading)
                  Row(children: const [
                    SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 10),
                    Text('Checking free disk space…', style: TextStyle(fontSize: 13)),
                  ])
                else if (_freeError != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.shade200),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_freeError!, style: TextStyle(color: Colors.red.shade700, fontSize: 12)),
                        const SizedBox(height: 6),
                        TextButton(onPressed: _refreshFreeSpace, child: const Text('Retry')),
                      ],
                    ),
                  )
                else ...[
                  Text('Allocate $_gb GB',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '$_freeGb GB free on this disk · max you can allocate: $_maxGb GB',
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                    ),
                  ),
                  Slider(
                    value: _gb.toDouble().clamp(_minGb.toDouble(), _maxGb.toDouble()),
                    min: _minGb.toDouble(),
                    max: _maxGb.toDouble(),
                    divisions: (_maxGb - _minGb).clamp(1, 200),
                    label: '$_gb GB',
                    onChanged: _busy ? null : (v) => setState(() => _gb = v.round()),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: quickPicks.map((g) {
                      return ChoiceChip(
                        label: Text('$g GB'),
                        selected: _gb == g,
                        onSelected: _busy ? null : (_) => setState(() => _gb = g),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'We reserve 10 GB for your operating system — you can\'t allocate that.',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.red.shade200),
                    ),
                    child: Text(_error!, style: TextStyle(color: Colors.red.shade700, fontSize: 13)),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _canCreate ? _create : null,
                  child: Text(_busy
                      ? 'Reserving ${formatBytes(_gb * 1024 * 1024 * 1024)}…'
                      : 'Create my drive'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
