import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../security/license_guard.dart';

/// Shown when the license guard has decided this install can't continue.
/// Reasons: revoked / invalid / offline-too-long.
class LicenseBlockedScreen extends ConsumerWidget {
  const LicenseBlockedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(licenseGuardProvider);
    final (title, body) = _copyFor(state.status, state.message);
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(Icons.lock_outline, size: 56, color: Colors.red.shade700),
                const SizedBox(height: 16),
                Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Text(body, textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade700, height: 1.5)),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => ref.read(licenseGuardProvider.notifier).bootstrap(),
                  child: const Text('Try again'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () async {
                    // Sign-out resets everything; user can log in to a different account.
                    await ref.read(licenseGuardProvider.notifier).bootstrap();
                  },
                  child: const Text('Contact support'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  (String, String) _copyFor(LicenseStatus s, String? msg) {
    switch (s) {
      case LicenseStatus.revoked:
        return (
          'License revoked',
          "This install of Weeber has been deactivated because it's been used in ways inconsistent with one license per person. If you believe this is a mistake, contact support.",
        );
      case LicenseStatus.invalid:
        return (
          'License could not be verified',
          'The activation receipt on this device failed cryptographic verification. Try again — if it keeps failing, the app may have been tampered with. Reinstall from the official site.',
        );
      case LicenseStatus.offline:
        return (
          'Offline too long',
          'Weeber needs to check in with our servers at least once every 7 days. Reconnect to the internet and try again.',
        );
      default:
        return ('Hold on', msg ?? 'Loading…');
    }
  }
}
