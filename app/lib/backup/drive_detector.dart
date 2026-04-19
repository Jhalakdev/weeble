import 'dart:io';
import 'package:path/path.dart' as p;
import 'marker.dart';

/// Lists every connected drive across macOS / Windows / Linux and looks for
/// the Weeber backup marker on each.
///
/// On macOS: enumerates `/Volumes/*`.
/// On Linux: enumerates `/media/$USER/*` and `/run/media/$USER/*`.
/// On Windows: enumerates drive letters via `wmic` (built-in tool).
class BackupDriveDetector {
  /// Returns every backup drive currently attached. Reads only the
  /// unauthenticated marker header (account_id + label + salt). Use the
  /// returned salt to derive the verify key and call [BackupMarker.readFromFolder]
  /// for full validation.
  static Future<List<DetectedDrive>> scan() async {
    final out = <DetectedDrive>[];
    for (final mountPoint in await _candidateMounts()) {
      final folderPath = p.join(mountPoint, BackupMarker.folderName);
      final peek = await BackupMarker.peek(folderPath);
      if (peek != null) {
        out.add(DetectedDrive(
          mountPoint: mountPoint,
          backupFolder: folderPath,
          accountId: peek.accountId,
          driveLabel: peek.driveLabel,
          kdfSalt: peek.kdfSalt,
        ));
      }
    }
    return out;
  }

  static Future<List<String>> _candidateMounts() async {
    if (Platform.isMacOS) {
      return _listSubdirs('/Volumes');
    }
    if (Platform.isLinux) {
      final user = Platform.environment['USER'] ?? Platform.environment['LOGNAME'] ?? 'root';
      final candidates = <String>[];
      candidates.addAll(await _listSubdirs('/media/$user'));
      candidates.addAll(await _listSubdirs('/run/media/$user'));
      candidates.addAll(await _listSubdirs('/mnt'));
      return candidates;
    }
    if (Platform.isWindows) {
      try {
        final r = await Process.run('wmic', ['logicaldisk', 'get', 'caption']);
        return r.stdout
            .toString()
            .split('\n')
            .map((l) => l.trim())
            .where((l) => RegExp(r'^[A-Za-z]:$').hasMatch(l))
            .map((l) => '$l\\')
            .toList();
      } catch (_) {
        return ['C:\\', 'D:\\', 'E:\\', 'F:\\']; // best-effort fallback
      }
    }
    // Mobile platforms can't host backup drives.
    return [];
  }

  static Future<List<String>> _listSubdirs(String root) async {
    final dir = Directory(root);
    if (!await dir.exists()) return [];
    try {
      final all = await dir.list(followLinks: false).toList();
      return all.whereType<Directory>().map((d) => d.path).toList();
    } catch (_) {
      return [];
    }
  }
}

class DetectedDrive {
  DetectedDrive({
    required this.mountPoint,
    required this.backupFolder,
    required this.accountId,
    required this.driveLabel,
    required this.kdfSalt,
  });

  final String mountPoint;
  final String backupFolder;
  final String accountId;
  final String driveLabel;
  final List<int> kdfSalt;
}
