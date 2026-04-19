import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../services/host_lifecycle.dart';
import '../../state/config.dart';

class EncryptionScreen extends ConsumerStatefulWidget {
  const EncryptionScreen({super.key});
  @override
  ConsumerState<EncryptionScreen> createState() => _EncryptionScreenState();
}

class _EncryptionScreenState extends ConsumerState<EncryptionScreen> {
  bool _enabled = true;
  bool _busy = false;

  Future<void> _continue() async {
    setState(() => _busy = true);
    await ref.read(appConfigProvider.notifier).update(
          (c) => c.copyWith(encryptionEnabled: _enabled, onboardingComplete: true),
        );
    // Now that onboarding is complete, kick the host lifecycle — this
    // registers the device, starts the file server, and announces to the
    // VPS (flipping the "Online" pill on every other device the user owns).
    // Don't await — we want the UI to proceed immediately.
    // ignore: unawaited_futures
    ref.read(hostLifecycleProvider).ensureRunning(forceTakeOver: true);
    if (mounted) context.go('/drive');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Encrypt your files?',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text(
                  'Weeber can encrypt every file with AES-256-GCM before writing it to disk. The encryption key is stored in your operating system\'s keychain.',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 15, height: 1.4),
                ),
                const SizedBox(height: 24),
                _Option(
                  selected: _enabled,
                  onTap: () => setState(() => _enabled = true),
                  title: 'Yes, encrypt my files (recommended)',
                  body: 'If your laptop is stolen or your disk is mounted on another machine, your files cannot be read.',
                ),
                const SizedBox(height: 12),
                _Option(
                  selected: !_enabled,
                  onTap: () => setState(() => _enabled = false),
                  title: 'No, store files unencrypted',
                  body: 'Slightly faster. Files can be read by anyone with access to the disk.',
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade50,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.amber.shade200),
                  ),
                  child: Text(
                    _enabled
                        ? 'Important: if you lose access to this device\'s keychain, your files cannot be decrypted. We cannot recover them.'
                        : 'You can enable encryption later, but existing files will not be re-encrypted.',
                    style: TextStyle(color: Colors.amber.shade900, fontSize: 13),
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _continue,
                  child: Text(_busy ? 'Setting up…' : 'Finish setup'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({required this.selected, required this.onTap, required this.title, required this.body});
  final bool selected;
  final VoidCallback onTap;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(color: selected ? Colors.black : Colors.grey.shade300, width: selected ? 1.5 : 1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: selected ? Colors.black : Colors.grey.shade400, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(body, style: TextStyle(color: Colors.grey.shade600, fontSize: 13, height: 1.4)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
