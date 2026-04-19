import 'dart:convert';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../state/auth.dart';
import '../state/config.dart';
import 'keypair.dart';

/// Registers this device as a CLIENT with the VPS and swaps the
/// account-bound JWT for a device-bound one (so the JWT carries `did`,
/// which the relay endpoints require for upload — without it the
/// server returns 400 no_device_binding).
///
/// Idempotent on the server (duplicate (account_id, pubkey, kind)
/// returns the existing device). Safe to call on every launch.
///
/// Mac/Linux/Windows hosts use HostLifecycle.ensureRunning which does
/// the host equivalent. Anything that runs as a CLIENT — phones,
/// demoted desktops — uses this.
class ClientRegistration {
  ClientRegistration({required this.ref});
  final Ref ref;

  Future<void> ensureRegistered() async {
    final auth = ref.read(authProvider);
    final cfg = ref.read(appConfigProvider);
    if (auth.token == null) return;
    // Already device-bound? Skip.
    if (cfg.deviceId != null && _hasDidClaim(auth.token!)) return;

    try {
      final kp = await DeviceKeypair.getOrCreate(ref.read(secureStorageProvider));
      final reg = await ref.read(apiProvider).registerDevice(
            token: auth.token!,
            kind: 'client',
            name: await _localDeviceName(),
            pubkey: kp.publicKeyB64,
          );
      await ref.read(authProvider.notifier).replaceToken(reg.token);
      await ref.read(appConfigProvider.notifier).update((c) => c.copyWith(deviceId: reg.deviceId));
    } catch (_) {
      // Network blip — we'll retry on the next launch. Until then,
      // upload will fail with no_device_binding (visible to the user
      // in the progress overlay) but list/download still work.
    }
  }

  static bool _hasDidClaim(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return false;
      final padded = parts[1].padRight((parts[1].length + 3) & ~3, '=');
      final normalized = padded.replaceAll('-', '+').replaceAll('_', '/');
      final json = utf8.decode(base64.decode(normalized));
      return json.contains('"did":"');
    } catch (_) {
      return false;
    }
  }

  static Future<String> _localDeviceName() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isIOS) {
        final i = await info.iosInfo;
        return '${i.name} (iOS ${i.systemVersion})';
      }
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        return '${a.brand} ${a.model} (Android ${a.version.release})';
      }
      if (Platform.isMacOS) return '${Platform.localHostname} (macOS)';
      if (Platform.isWindows) return '${Platform.localHostname} (Windows)';
      if (Platform.isLinux) return '${Platform.localHostname} (Linux)';
    } catch (_) {}
    return Platform.localHostname;
  }
}

final clientRegistrationProvider = Provider<ClientRegistration>((ref) => ClientRegistration(ref: ref));
