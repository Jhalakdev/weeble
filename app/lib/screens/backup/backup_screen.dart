import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../backup/backup_service.dart';
import '../../backup/drive_detector.dart';
import '../../backup/passphrase.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/byte_size.dart';

class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});
  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  List<DetectedDrive> _drives = [];
  bool _scanning = true;
  bool _busy = false;
  double _progress = 0;
  String _currentFile = '';
  String? _error;
  String? _success;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    final drives = await BackupDriveDetector.scan();
    if (mounted) setState(() {
      _drives = drives;
      _scanning = false;
    });
  }

  Future<void> _setupNewDrive() async {
    final mount = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Pick a folder on the drive you want to use for backups');
    if (mount == null) return;
    if (!mounted) return;

    final result = await showDialog<({String label, String passphrase})>(
      context: context,
      builder: (_) => const _SetupDialog(),
    );
    if (result == null) return;

    setState(() {
      _busy = true;
      _error = null;
      _success = null;
    });
    try {
      await ref.read(backupServiceProvider).setupDrive(
            mountPoint: mount,
            driveLabel: result.label,
            passphrase: result.passphrase,
          );
      await _scan();
      setState(() => _success = 'Backup drive ready. Now click "Backup now".');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _backupNow(DetectedDrive drive) async {
    final pp = await showDialog<String>(
      context: context,
      builder: (_) => const _PassphraseDialog(title: 'Unlock backup drive', hint: 'Enter the passphrase you set for this drive.'),
    );
    if (pp == null) return;
    setState(() {
      _busy = true;
      _progress = 0;
      _currentFile = '';
      _error = null;
      _success = null;
    });
    try {
      final res = await ref.read(backupServiceProvider).backupTo(
            drive: drive,
            passphrase: pp,
            onProgress: (pct, file) {
              if (mounted) setState(() {
                _progress = pct;
                _currentFile = file;
              });
            },
          );
      setState(() => _success = 'Backup complete: ${res.fileCount} files (${formatBytes(res.totalBytes)}).');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: 'Backup',
      activeRoute: '/backup',
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Choose a backup destination',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('Pick a USB drive or external hard disk and store it somewhere safe. Files are encrypted with your passphrase before they leave this device — even if the drive is stolen, your data is unreadable.',
                style: TextStyle(color: Colors.grey.shade700, height: 1.5)),
            const SizedBox(height: 24),
            if (_scanning)
              const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
            else if (_drives.isEmpty)
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(8)),
                child: Column(
                  children: [
                    Icon(Icons.usb, size: 48, color: Colors.grey.shade400),
                    const SizedBox(height: 12),
                    const Text('No backup drives detected'),
                    const SizedBox(height: 4),
                    Text('Plug in a USB drive or external hard disk, then click below.',
                        textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _busy ? null : _setupNewDrive,
                      icon: const Icon(Icons.add),
                      label: const Text('Set up a backup drive'),
                    ),
                  ],
                ),
              )
            else ...[
              for (final d in _drives) ...[
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.usb),
                    title: Text(d.driveLabel),
                    subtitle: Text(d.mountPoint, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                    trailing: FilledButton.tonal(
                      onPressed: _busy ? null : () => _backupNow(d),
                      child: const Text('Backup now'),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              TextButton.icon(
                onPressed: _busy ? null : _setupNewDrive,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add another backup drive'),
              ),
            ],

            const SizedBox(height: 24),

            // Cloud option
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(8)),
              child: Row(
                children: [
                  Icon(Icons.cloud_outlined, color: Colors.grey.shade700, size: 32),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Weeber Cloud Backup', style: TextStyle(fontWeight: FontWeight.w600)),
                        SizedBox(height: 4),
                        Text('Geographic redundancy, no drive to manage. From \$3/mo.',
                            style: TextStyle(fontSize: 13)),
                      ],
                    ),
                  ),
                  OutlinedButton(
                    onPressed: () {},
                    child: const Text('Coming soon'),
                  ),
                ],
              ),
            ),

            if (_busy) ...[
              const SizedBox(height: 24),
              LinearProgressIndicator(value: _progress > 0 ? _progress : null),
              const SizedBox(height: 6),
              Text(_currentFile, style: TextStyle(fontSize: 12, color: Colors.grey.shade600), maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.red.shade200)),
                child: Text(_error!, style: TextStyle(color: Colors.red.shade800, fontSize: 13)),
              ),
            ],
            if (_success != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.green.shade200)),
                child: Text(_success!, style: TextStyle(color: Colors.green.shade900, fontSize: 13)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SetupDialog extends StatefulWidget {
  const _SetupDialog();
  @override
  State<_SetupDialog> createState() => _SetupDialogState();
}

class _SetupDialogState extends State<_SetupDialog> {
  final _label = TextEditingController(text: 'Backup drive');
  final _pp = TextEditingController(text: BackupKdf.suggest());
  final _pp2 = TextEditingController();
  bool _obscure = true;
  String? _err;

  @override
  Widget build(BuildContext context) {
    final (str, msg) = BackupKdf.strength(_pp.text);
    final color = str == 'strong' ? Colors.green : str == 'fair' ? Colors.amber : Colors.red;
    return AlertDialog(
      title: const Text('Set up backup drive'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _label,
              decoration: const InputDecoration(labelText: 'Drive name', helperText: 'e.g., "Black Seagate 2TB"'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _pp,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Recovery passphrase',
                helperText: 'WRITE THIS DOWN. Without it, your backup is unrecoverable.',
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(msg, style: TextStyle(color: color, fontSize: 12)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pp2,
              obscureText: _obscure,
              decoration: const InputDecoration(labelText: 'Confirm passphrase'),
            ),
            if (_err != null) Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_err!, style: TextStyle(color: Colors.red.shade700, fontSize: 12)),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Suggest a strong passphrase'),
              onPressed: () => setState(() => _pp.text = BackupKdf.suggest()),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (_pp.text.length < 8) {
              setState(() => _err = 'Passphrase too short.');
              return;
            }
            if (_pp.text != _pp2.text) {
              setState(() => _err = "Passphrases don't match.");
              return;
            }
            Navigator.pop(context, (label: _label.text.trim(), passphrase: _pp.text));
          },
          child: const Text('Create backup drive'),
        ),
      ],
    );
  }
}

class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog({required this.title, required this.hint});
  final String title;
  final String hint;
  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _ctrl = TextEditingController();
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        obscureText: _obscure,
        autofocus: true,
        onSubmitted: (_) => Navigator.pop(context, _ctrl.text),
        decoration: InputDecoration(
          labelText: 'Passphrase',
          helperText: widget.hint,
          suffixIcon: IconButton(
            icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, _ctrl.text), child: const Text('Continue')),
      ],
    );
  }
}
