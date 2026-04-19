import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../api/client.dart';
import '../../services/pairing.dart';
import '../../state/auth.dart';
import '../../state/config.dart';

/// Shown on the host. Generates a fresh pairing token every ~25s. The QR
/// encodes a JSON payload (PairingPayload) that the mobile app can scan
/// and turn into a logged-in client device.
class HostQrScreen extends ConsumerStatefulWidget {
  const HostQrScreen({super.key});
  @override
  ConsumerState<HostQrScreen> createState() => _HostQrScreenState();
}

class _HostQrScreenState extends ConsumerState<HostQrScreen> {
  Timer? _timer;
  PairingPayload? _payload;
  String? _error;
  Duration _remaining = Duration.zero;

  static const _refreshSeconds = 25;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _tick() {
    if (_payload == null) return;
    final left = _payload!.expiresAt - DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (left <= 0) {
      _refresh();
      return;
    }
    setState(() => _remaining = Duration(seconds: left));
  }

  Future<void> _refresh() async {
    final auth = ref.read(authProvider);
    final cfg = ref.read(appConfigProvider);
    if (auth.token == null) return;
    try {
      final res = await ref.read(apiProvider).createPairingToken(auth.token!);
      const apiUrl = String.fromEnvironment('WEEBER_API_URL', defaultValue: 'http://localhost:3030');
      final payload = PairingPayload(
        token: res['token'] as String,
        apiUrl: apiUrl,
        hostDeviceId: cfg.deviceId ?? 'unregistered',
        hostName: 'Weeber host',
        expiresAt: res['expires_at'] as int,
      );
      if (!mounted) return;
      setState(() {
        _payload = payload;
        _error = null;
      });
      // Refresh slightly before the token actually expires to avoid showing a dead QR.
      Timer(Duration(seconds: _refreshSeconds), () { if (mounted) _refresh(); });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.code);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            } else {
              GoRouter.of(context).go('/drive');
            }
          },
        ),
        title: const Text('Pair a new device'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'Open Weeber on your phone and scan this code.',
                  style: TextStyle(fontSize: 16),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                if (_error != null)
                  Text('Error: $_error', style: TextStyle(color: Colors.red.shade700))
                else if (_payload == null)
                  const CircularProgressIndicator()
                else
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: QrImageView(
                      data: _payload!.encode(),
                      size: 280,
                      backgroundColor: Colors.white,
                    ),
                  ),
                const SizedBox(height: 16),
                if (_payload != null)
                  Text(
                    'Refreshes in ${_remaining.inSeconds}s',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                  ),
                const SizedBox(height: 32),
                Text(
                  'For security, this code rotates every ${_refreshSeconds}s. Once scanned, the device stays paired.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13, height: 1.4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
