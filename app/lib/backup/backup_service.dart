import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../state/auth.dart';
import '../state/config.dart';
import 'drive_detector.dart';
import 'key_wrap.dart';
import 'marker.dart';
import 'passphrase.dart';
import 'snapshot_engine.dart';

/// Orchestrates the full backup lifecycle. Doesn't talk to the network for
/// local backups; cloud backup variant uploads via SFTP (TODO).
class BackupService {
  BackupService({required this.ref});
  final Ref ref;

  /// Sets up a new backup drive. The passphrase is what the user types now
  /// AND must remember forever to restore. We never store it.
  ///
  /// Returns the drive's marker; on success the marker file is written and
  /// the WeeberBackup folder is created on the drive.
  Future<BackupSetupResult> setupDrive({
    required String mountPoint,
    required String driveLabel,
    required String passphrase,
  }) async {
    final accountId = ref.read(authProvider).accountId;
    if (accountId == null) throw StateError('not_logged_in');

    final folderPath = p.join(mountPoint, BackupMarker.folderName);
    await Directory(folderPath).create(recursive: true);

    final salt = BackupKdf.newSalt();
    final argon = await BackupKdf.derive(passphrase: passphrase, salt: salt);
    final split = KeySplit.fromArgon(argon);
    final keys = await WrappedKey.generate(split.kek);

    final marker = BackupMarker(
      driveId: _ulid(),
      accountId: accountId,
      driveLabel: driveLabel,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      lastBackupAt: 0,
      kdfSalt: salt,
      wrappedMasterKey: keys.wrap.ciphertext,
      wrapperNonce: keys.wrap.nonce,
      wrapperMac: keys.wrap.mac,
    );
    await marker.writeTo(folderPath, split.macKey);
    await _writeRecoveryReadme(folderPath);
    return BackupSetupResult(marker: marker, masterKey: keys.masterKey, macKey: split.macKey, folderPath: folderPath);
  }

  /// Run a snapshot of the user's storage folder onto the given backup drive.
  /// Caller must have already unlocked the drive (resolved master key + mac key
  /// from a passphrase).
  Future<SnapshotResult> backupTo({
    required DetectedDrive drive,
    required String passphrase,
    void Function(double, String)? onProgress,
  }) async {
    final cfg = ref.read(appConfigProvider);
    final source = cfg.storagePath;
    if (source == null) throw StateError('no_storage_path');

    final argon = await BackupKdf.derive(passphrase: passphrase, salt: drive.kdfSalt);
    final split = KeySplit.fromArgon(argon);
    final marker = await BackupMarker.readFromFolder(drive.backupFolder, macKeyForVerify: () => split.macKey);
    if (marker == null) throw StateError('passphrase_wrong_or_marker_corrupt');

    final masterKey = await WrappedKey(
      ciphertext: marker.wrappedMasterKey,
      nonce: marker.wrapperNonce,
      mac: marker.wrapperMac,
    ).unwrap(split.kek);

    final engine = SnapshotEngine(masterKey: masterKey, macKey: split.macKey);
    return engine.create(sourceFolder: source, backupFolder: drive.backupFolder, onProgress: onProgress);
  }

  /// Restore the most recent (or specified) snapshot from a backup drive into
  /// [destinationFolder].
  Future<RestoreResult> restoreFrom({
    required DetectedDrive drive,
    required String passphrase,
    required String destinationFolder,
    String? snapshotId,
    void Function(double, String)? onProgress,
  }) async {
    final argon = await BackupKdf.derive(passphrase: passphrase, salt: drive.kdfSalt);
    final split = KeySplit.fromArgon(argon);
    final marker = await BackupMarker.readFromFolder(drive.backupFolder, macKeyForVerify: () => split.macKey);
    if (marker == null) throw StateError('passphrase_wrong_or_marker_corrupt');

    final masterKey = await WrappedKey(
      ciphertext: marker.wrappedMasterKey,
      nonce: marker.wrapperNonce,
      mac: marker.wrapperMac,
    ).unwrap(split.kek);

    // Pick most recent snapshot if none specified.
    final snapsRoot = Directory(p.join(drive.backupFolder, 'snapshots'));
    if (!await snapsRoot.exists()) throw StateError('no_snapshots');
    final all = await snapsRoot.list(followLinks: false).toList();
    final snaps = all.whereType<Directory>().toList()
      ..sort((a, b) => p.basename(b.path).compareTo(p.basename(a.path)));
    if (snaps.isEmpty) throw StateError('no_snapshots');
    final chosen = snapshotId == null
        ? snaps.first
        : snaps.firstWhere((d) => p.basename(d.path) == snapshotId);

    final engine = SnapshotEngine(masterKey: masterKey, macKey: split.macKey);
    return engine.restore(snapshotDir: chosen.path, destinationFolder: destinationFolder, onProgress: onProgress);
  }

  Future<void> _writeRecoveryReadme(String folderPath) async {
    final f = File(p.join(folderPath, 'RECOVERY.txt'));
    await f.writeAsString('''
WEEBER BACKUP DRIVE — RECOVERY INSTRUCTIONS

This drive contains an encrypted backup of files from a Weeber installation.
To restore:

  1. Install Weeber on any Mac, Windows or Linux machine from https://weeber.app
  2. Log in with the account that originally created this backup
  3. The app will detect this drive automatically — you'll see a "Restore from backup"
     option on the Drive screen
  4. Enter the recovery passphrase you set when you created this backup
  5. Pick a folder where Weeber should restore the files

If you lose the recovery passphrase, the data on this drive is unrecoverable.
We cannot help — by design, the encryption keys live only in your head and
this drive. This is what protects your files from anyone who steals the drive.

Weeber version: 0.1
Format version: 1
''');
  }

  static String _ulid() {
    final t = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final r = (DateTime.now().microsecondsSinceEpoch & 0xfffffff).toRadixString(36);
    return '$t-$r';
  }
}

class BackupSetupResult {
  BackupSetupResult({required this.marker, required this.masterKey, required this.macKey, required this.folderPath});
  final BackupMarker marker;
  final List<int> masterKey;
  final List<int> macKey;
  final String folderPath;
}

final backupServiceProvider = Provider<BackupService>((ref) => BackupService(ref: ref));
