import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
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
                const Text('Another machine is your server now',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Text(
                  "You can only have one Weeber server at a time. Another device on your account just took over. Your phones will now talk to that machine.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade700, height: 1.5),
                ),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: () async {
                    // The user wants this machine to be the server again.
                    // Real take-over needs the current public_ip/port/cert,
                    // which the host server module knows. For now, we route to
                    // a flow that re-runs the host startup with takeOver=true.
                    await _takeOver(ref);
                    if (context.mounted) context.go('/drive');
                  },
                  icon: const Icon(Icons.dns_outlined),
                  label: const Text('Take it back — make this my server'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => context.go('/drive'),
                  child: const Text('Use as a client only'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _takeOver(WidgetRef ref) async {
    // TODO: wire to the actual host_server lifecycle once it's started by main.
    // For now we just toggle the role state optimistically — the next heartbeat
    // will reconcile against the server.
    await ref.read(hostRoleProvider.notifier).announce(
          publicIp: '0.0.0.0',
          port: 0,
          reachability: 'unknown',
          certFingerprint: '',
          takeOver: true,
        );
  }
}
