import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';

/// Stable per-machine identifier. We hash multiple sources together so that
/// the resulting fingerprint:
///   - is the same on every launch on the same machine (stable)
///   - is different on different machines (unique)
///   - reveals nothing identifiable in raw form (just a SHA-256 hex)
///
/// Stored only on our server, never displayed to other users.
class HardwareFingerprint {
  static String? _cached;

  static Future<String> compute() async {
    if (_cached != null) return _cached!;
    final info = DeviceInfoPlugin();
    final parts = <String>[];

    if (Platform.isMacOS) {
      final m = await info.macOsInfo;
      parts.addAll([m.systemGUID ?? '', m.computerName, m.model, m.kernelVersion]);
    } else if (Platform.isWindows) {
      final w = await info.windowsInfo;
      parts.addAll([w.deviceId, w.computerName, w.systemMemoryInMegabytes.toString()]);
    } else if (Platform.isLinux) {
      final l = await info.linuxInfo;
      parts.addAll([l.machineId ?? '', l.name, l.version ?? '']);
    } else if (Platform.isAndroid) {
      final a = await info.androidInfo;
      parts.addAll([a.id, a.fingerprint, a.hardware, a.bootloader, a.serialNumber]);
    } else if (Platform.isIOS) {
      final i = await info.iosInfo;
      parts.addAll([i.identifierForVendor ?? '', i.model, i.systemVersion]);
    } else {
      parts.add('unknown-platform');
    }

    final raw = parts.where((s) => s.isNotEmpty).join('|');
    final digest = sha256.convert(utf8.encode('weeber-fp-v1:$raw'));
    _cached = digest.toString(); // 64 hex chars
    return _cached!;
  }

  static String get platform {
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'web';
  }
}
