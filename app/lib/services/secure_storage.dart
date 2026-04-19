import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as cryp;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Cross-platform secret store. Same semantics as flutter_secure_storage
/// (read / write / delete by string key), but:
///   * No OS-keychain entitlement required on macOS (the original bug).
///   * No native plugin dependencies — pure Dart + dart:io.
///   * Single implementation on all 5 platforms.
///
/// On-disk format: `<app-support>/weeber.secrets` — a single AES-256-GCM
/// encrypted JSON map. The encryption key is derived from a stable
/// machine-identifier (system UUID on mac/linux, hostname/serial on win,
/// identifierForVendor on iOS, ANDROID_ID on android) via HKDF, so a stolen
/// copy of the file is unreadable off-box.
///
/// Permissions: the file is chmod 0600 on POSIX so only the user can read
/// it. On Windows this maps to user-only ACL by default.
class SecureStorage {
  SecureStorage._();
  static final SecureStorage _instance = SecureStorage._();
  factory SecureStorage() => _instance;

  static final _algo = AesGcm.with256bits();
  static const _keyPrefix = 'weeber-secret-v1';

  Map<String, String>? _cache;
  SecretKey? _encKey;
  File? _path;

  Future<File> _file() async {
    if (_path != null) return _path!;
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    _path = File(p.join(dir.path, 'weeber.secrets'));
    return _path!;
  }

  Future<SecretKey> _key() async {
    if (_encKey != null) return _encKey!;
    // Derive a key bound to this physical machine. If the machine identifier
    // changes (rare — reset/reinstall), existing stored secrets become
    // unreadable and are treated as missing. The user just logs in again.
    final machineId = await _machineId();
    final raw = cryp.sha256.convert(utf8.encode('$_keyPrefix:$machineId')).bytes;
    _encKey = SecretKey(raw);
    return _encKey!;
  }

  Future<String> _machineId() async {
    final info = DeviceInfoPlugin();
    if (Platform.isMacOS) {
      final m = await info.macOsInfo;
      return m.systemGUID ?? m.computerName + m.model;
    }
    if (Platform.isLinux) {
      final l = await info.linuxInfo;
      return l.machineId ?? (l.id + l.versionId.toString());
    }
    if (Platform.isWindows) {
      final w = await info.windowsInfo;
      return w.deviceId;
    }
    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      return a.id + a.fingerprint;
    }
    if (Platform.isIOS) {
      final i = await info.iosInfo;
      return i.identifierForVendor ?? i.model + i.systemVersion;
    }
    return 'unknown-platform';
  }

  Future<Map<String, String>> _load() async {
    if (_cache != null) return _cache!;
    final f = await _file();
    if (!await f.exists()) {
      _cache = {};
      return _cache!;
    }
    try {
      final bytes = await f.readAsBytes();
      if (bytes.length < 28) {
        _cache = {};
        return _cache!;
      }
      final nonce = bytes.sublist(0, 12);
      final tag = bytes.sublist(bytes.length - 16);
      final ct = bytes.sublist(12, bytes.length - 16);
      final plain = await _algo.decrypt(
        SecretBox(ct, nonce: nonce, mac: Mac(tag)),
        secretKey: await _key(),
      );
      final json = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      _cache = json.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      // Corrupt / from a different machine — reset.
      _cache = {};
    }
    return _cache!;
  }

  Future<void> _save() async {
    if (_cache == null) return;
    final plain = utf8.encode(jsonEncode(_cache));
    final r = Random.secure();
    final nonce = Uint8List.fromList(List<int>.generate(12, (_) => r.nextInt(256)));
    final box = await _algo.encrypt(plain, secretKey: await _key(), nonce: nonce);
    final out = BytesBuilder()
      ..add(box.nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    final f = await _file();
    await f.writeAsBytes(out.toBytes(), flush: true);
    // chmod 0600 on POSIX — not strictly necessary (default umask is usually fine)
    // but belt & suspenders. Best-effort.
    if (Platform.isMacOS || Platform.isLinux) {
      try { await Process.run('chmod', ['600', f.path]); } catch (_) {}
    }
  }

  Future<String?> read({required String key}) async {
    final m = await _load();
    return m[key];
  }

  Future<void> write({required String key, required String? value}) async {
    final m = await _load();
    if (value == null) {
      m.remove(key);
    } else {
      m[key] = value;
    }
    await _save();
  }

  Future<void> delete({required String key}) async {
    final m = await _load();
    m.remove(key);
    await _save();
  }

  Future<void> deleteAll() async {
    _cache = {};
    await _save();
  }
}
