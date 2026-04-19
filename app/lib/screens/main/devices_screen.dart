import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../api/client.dart';
import '../../state/auth.dart';
import '../../widgets/app_shell.dart';

class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});
  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  List<Map<String, dynamic>> _devices = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final auth = ref.read(authProvider);
    if (auth.token == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ref.read(apiProvider).listDevices(auth.token!);
      if (mounted) setState(() => _devices = list);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.code);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _rename(Map<String, dynamic> d) async {
    final ctrl = TextEditingController(text: d['name'] as String);
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Rename device'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (newName == null || newName.isEmpty) return;
    final auth = ref.read(authProvider);
    try {
      await ref.read(apiProvider).renameDevice(token: auth.token!, id: d['id'] as String, name: newName);
      await _refresh();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Rename failed: ${e.code}')));
    }
  }

  Future<void> _revoke(Map<String, dynamic> d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sign this device out?'),
        content: Text('${d['name']} will lose access in under a minute.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final auth = ref.read(authProvider);
    try {
      await ref.read(apiProvider).revokeDevice(token: auth.token!, id: d['id'] as String);
      await _refresh();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sign-out failed: ${e.code}')));
    }
  }

  String _agoString(int unix) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final delta = now - unix;
    if (delta < 60) return 'just now';
    if (delta < 3600) return '${delta ~/ 60} min ago';
    if (delta < 86400) return '${delta ~/ 3600} h ago';
    return '${delta ~/ 86400} d ago';
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: 'Devices',
      activeRoute: '/devices',
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Error: $_error'))
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _devices.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final d = _devices[i];
                      final kind = d['kind'] as String;
                      final platform = d['platform'] as String;
                      return ListTile(
                        leading: Icon(_iconFor(platform, kind)),
                        title: Text(d['name'] as String),
                        subtitle: Text('${kind == 'host' ? 'Server' : 'Client'} · $platform · last seen ${_agoString(d['last_seen_at'] as int)}'),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'rename') _rename(d);
                            if (v == 'revoke') _revoke(d);
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'rename', child: Text('Rename')),
                            PopupMenuItem(value: 'revoke', child: Text('Sign out', style: TextStyle(color: Colors.red))),
                          ],
                        ),
                      );
                    },
                  ),
                ),
    );
  }

  IconData _iconFor(String platform, String kind) {
    if (kind == 'host') return Icons.dns_outlined;
    return switch (platform) {
      'ios' || 'android' => Icons.smartphone_outlined,
      'macos' => Icons.laptop_mac,
      'windows' => Icons.laptop_windows,
      'linux' => Icons.computer_outlined,
      _ => Icons.devices,
    };
  }
}
