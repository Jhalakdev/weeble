import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'passphrase.dart';

/// The on-disk marker that identifies a Weeber backup drive.
///
/// Layout on the drive:
///   <root>/WeeberBackup/.weeber-backup        ← this marker file (JSON)
///   <root>/WeeberBackup/snapshots/            ← snapshot directories
///   <root>/WeeberBackup/recovery.txt          ← human-readable instructions
///
/// The marker is HMAC-signed with a key derived from the user's passphrase, so
/// nobody can forge a marker that claims our format without knowing the
/// passphrase. The wrapped master key is also inside, protected by the same
/// passphrase. So everything needed to restore is on the drive itself; even
/// total loss of our servers + the user's host machine + the keychain leaves
/// the user able to recover, given the drive + the passphrase.
class BackupMarker {
  BackupMarker({
    required this.driveId,
    required this.accountId,
    required this.driveLabel,
    required this.createdAt,
    required this.lastBackupAt,
    required this.kdfSalt,
    required this.wrappedMasterKey,
    required this.wrapperNonce,
    required this.wrapperMac,
  });

  static const fileName = '.weeber-backup';
  static const folderName = 'WeeberBackup';
  static const _formatVersion = 1;

  final String driveId;
  final String accountId;
  final String driveLabel;
  final int createdAt;
  final int lastBackupAt;
  final List<int> kdfSalt;
  final List<int> wrappedMasterKey;
  final List<int> wrapperNonce;
  final List<int> wrapperMac;

  /// Returns the path to this marker file given a backup-folder root.
  static String pathInFolder(String folderPath) => p.join(folderPath, fileName);

  Map<String, Object?> _payloadJson() => {
        'version': _formatVersion,
        'drive_id': driveId,
        'account_id': accountId,
        'drive_label': driveLabel,
        'created_at': createdAt,
        'last_backup_at': lastBackupAt,
        'kdf': 'argon2id',
        'kdf_params': {
          'memory': BackupKdf.memory,
          'iterations': BackupKdf.iterations,
          'parallelism': BackupKdf.parallelism,
        },
        'kdf_salt': base64.encode(kdfSalt),
        'wrapped_master_key': base64.encode(wrappedMasterKey),
        'wrapper_nonce': base64.encode(wrapperNonce),
        'wrapper_mac': base64.encode(wrapperMac),
      };

  Future<Map<String, Object?>> toSignedJson(List<int> macKey) async {
    final payload = _payloadJson();
    final canonical = utf8.encode(jsonEncode(payload));
    final mac = await Hmac.sha256().calculateMac(canonical, secretKey: SecretKey(macKey));
    return {...payload, 'signature': base64.encode(mac.bytes)};
  }

  static Future<BackupMarker?> readFromFolder(String folderPath, {required List<int> Function() macKeyForVerify}) async {
    final f = File(pathInFolder(folderPath));
    if (!await f.exists()) return null;
    final raw = await f.readAsString();
    Map<String, dynamic> j;
    try {
      j = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    if (j['version'] != _formatVersion) return null;

    final sig = base64.decode(j['signature'] as String);
    final payloadOnly = Map<String, dynamic>.of(j)..remove('signature');
    final canonical = utf8.encode(jsonEncode(payloadOnly));
    final mac = await Hmac.sha256().calculateMac(canonical, secretKey: SecretKey(macKeyForVerify()));
    if (!_constantTimeEquals(mac.bytes, sig)) return null;

    return BackupMarker(
      driveId: j['drive_id'] as String,
      accountId: j['account_id'] as String,
      driveLabel: j['drive_label'] as String,
      createdAt: j['created_at'] as int,
      lastBackupAt: j['last_backup_at'] as int,
      kdfSalt: base64.decode(j['kdf_salt'] as String),
      wrappedMasterKey: base64.decode(j['wrapped_master_key'] as String),
      wrapperNonce: base64.decode(j['wrapper_nonce'] as String),
      wrapperMac: base64.decode(j['wrapper_mac'] as String),
    );
  }

  /// Reads only the unauthenticated header — for "what account is this drive
  /// linked to" before we have the passphrase. Use this to identify the drive,
  /// then prompt for the passphrase, then verify with [readFromFolder].
  static Future<({String accountId, String driveLabel, List<int> kdfSalt})?> peek(String folderPath) async {
    final f = File(pathInFolder(folderPath));
    if (!await f.exists()) return null;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      if (j['version'] != _formatVersion) return null;
      return (
        accountId: j['account_id'] as String,
        driveLabel: j['drive_label'] as String,
        kdfSalt: base64.decode(j['kdf_salt'] as String),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> writeTo(String folderPath, List<int> macKey) async {
    final dir = Directory(folderPath);
    if (!await dir.exists()) await dir.create(recursive: true);
    final signed = await toSignedJson(macKey);
    await File(pathInFolder(folderPath)).writeAsString(jsonEncode(signed), flush: true);
  }
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff == 0;
}
