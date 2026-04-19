import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class WelcomeScreen extends ConsumerWidget {
  const WelcomeScreen({super.key});

  bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text("You're in!",
                    style: TextStyle(fontSize: 32, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                Text(
                  _isDesktop
                      ? "Let's set this device up as your storage. Two quick steps:"
                      : "This device will act as a client for your Weeber storage. Pair it with the device running Weeber as a server.",
                  style: TextStyle(fontSize: 16, color: Colors.grey.shade700, height: 1.4),
                ),
                const SizedBox(height: 24),
                if (_isDesktop) ...[
                  _Step(num: 1, title: 'Allocate storage', body: 'Choose how much of your drive to dedicate to Weeber.'),
                  const SizedBox(height: 12),
                  _Step(num: 2, title: 'Encryption (optional)', body: 'Encrypt your files at rest with AES-256.'),
                  const SizedBox(height: 32),
                  FilledButton(
                    onPressed: () => context.go('/onboarding/storage'),
                    child: const Text('Continue'),
                  ),
                ] else ...[
                  const SizedBox(height: 32),
                  FilledButton(
                    onPressed: () => context.go('/pair'),
                    child: const Text('Pair with my server'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.num, required this.title, required this.body});
  final int num;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text('$num', style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(body, style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
            ],
          ),
        ),
      ],
    );
  }
}
