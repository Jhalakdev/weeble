import 'dart:io';
import 'package:path/path.dart' as p;

/// Queries the actual free disk space for a given path by shelling out to
/// platform tools. More reliable than any third-party package — works
/// identically on macOS, Linux, and Windows; always returns *real* free
/// bytes or throws.
class DiskSpace {
  /// Returns free bytes on the filesystem that contains [path]. Throws on
  /// failure — the caller must treat "unknown" as "can't continue".
  static Future<int> freeBytes(String path) async {
    // Use the PARENT directory if path doesn't exist yet (common during
    // onboarding when the storage folder hasn't been created).
    final dir = await Directory(path).exists() ? path : p.dirname(path);
    if (Platform.isMacOS || Platform.isLinux) {
      return _posix(dir);
    }
    if (Platform.isWindows) {
      return _windows(dir);
    }
    throw UnsupportedError('disk space query not supported on this platform');
  }

  static Future<int> _posix(String dir) async {
    // `df -P -k "<dir>"` outputs two lines:
    //   Filesystem 1024-blocks Used Available Capacity Mounted-on
    //   /dev/disk  ...        ...  <freeKb>  ...%     /...
    final r = await Process.run('df', ['-P', '-k', dir]);
    if (r.exitCode != 0) throw Exception('df failed: ${r.stderr}');
    final lines = r.stdout.toString().split('\n');
    if (lines.length < 2) throw Exception('df parse failed');
    final parts = lines[1].split(RegExp(r'\s+'));
    if (parts.length < 4) throw Exception('df parse failed');
    final freeKb = int.parse(parts[3]);
    return freeKb * 1024;
  }

  static Future<int> _windows(String dir) async {
    // Extract drive letter, e.g. "C:"
    final drive = dir.length >= 2 ? dir.substring(0, 2) : 'C:';
    // wmic is deprecated but works; PowerShell fallback below.
    try {
      final r = await Process.run('wmic', [
        'logicaldisk', 'where', 'DeviceID="$drive"', 'get', 'FreeSpace', '/value',
      ]);
      if (r.exitCode == 0) {
        final m = RegExp(r'FreeSpace=(\d+)').firstMatch(r.stdout.toString());
        if (m != null) return int.parse(m.group(1)!);
      }
    } catch (_) {}
    // PowerShell fallback
    final r2 = await Process.run('powershell', [
      '-Command',
      '(Get-PSDrive -Name ${drive.substring(0, 1)}).Free',
    ]);
    if (r2.exitCode != 0) throw Exception('disk query failed');
    return int.parse(r2.stdout.toString().trim());
  }
}
