import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../services/host_lifecycle.dart';
import '../../state/host_role.dart';

/// Shown to a host machine that has been replaced by another. The user can
/// either accept (and use this machine as a client only) or take it back.
class DemotedScreen extends ConsumerWidget {
  const DemotedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                Icon(Icons.swap_horiz, size: 56, color: Colors.amber.shade800),
                const SizedBox(height: 16),
                const Text('Your account is hosted on another computer',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Text(
                  "Just like WhatsApp, only one computer can host your files at a time. "
                  "While this Mac was offline, you set up Weeber on another computer — that's now the host.\n\n"
                  "If you switch back, files added on the OTHER computer won't appear here automatically — they live on that machine.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade700, height: 1.5),
                ),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: () async {
                    // User wants this machine to host again. Run the full
                    // host lifecycle with forceTakeOver=true; the other
                    // machine will get demoted on its next heartbeat.
                    await ref.read(hostLifecycleProvider).ensureRunning(forceTakeOver: true);
                    if (context.mounted) context.go('/drive');
                  },
                  icon: const Icon(Icons.dns_outlined),
                  label: const Text('Switch back to this Mac'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () {
                    // Stay as a client. Mark role notHost so the router
                    // sends us to the client drive screen instead of
                    // bouncing back here.
                    ref.read(hostRoleProvider.notifier).setClientOnly();
                    context.go('/drive');
                  },
                  child: const Text('Stay as a client on this Mac'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

}
