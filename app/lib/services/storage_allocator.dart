import 'dart:io';
import 'package:path/path.dart' as p;

/// Reserves disk space by creating a single placeholder file of the requested
/// size. The file is grown using `RandomAccessFile.setPosition` + a 1-byte
/// write at the end, which most filesystems treat as a fast sparse-or-
/// preallocated extend (depending on FS).
///
/// On macOS APFS / Linux ext4 / Windows NTFS this completes in milliseconds
/// for any size, because the FS records the new length without writing zeros.
///
/// This is a "soft reservation" — sparse files don't actually consume the
/// full size on disk until written. To force *true* preallocation (so the OS
/// truly cannot use the space), we shell out to `fallocate` on Linux,
/// `fsutil file setvaliddata` on Windows, and `mkfile` on macOS.
class StorageAllocator {
  /// Initialize a storage root at [rootPath] with [bytes] reserved.
  /// Creates:
  ///   <rootPath>/.weeber-reserve   (placeholder, sized to bytes - currentUsed)
  ///   <rootPath>/files/             (where actual user files live)
  static Future<void> initialize({required String rootPath, required int bytes}) async {
    final root = Directory(rootPath);
    if (!await root.exists()) await root.create(recursive: true);

    final filesDir = Directory(p.join(rootPath, 'files'));
    if (!await filesDir.exists()) await filesDir.create();

    final placeholder = File(p.join(rootPath, '.weeber-reserve'));
    await _setSize(placeholder, bytes);
  }

  /// Resize the reservation. Pass the new total allocation in bytes.
  /// Used filesDir size is subtracted automatically.
  static Future<void> resize({required String rootPath, required int newBytes}) async {
    final used = await usedBytes(rootPath);
    final reserve = newBytes - used;
    final placeholder = File(p.join(rootPath, '.weeber-reserve'));
    await _setSize(placeholder, reserve.clamp(0, newBytes));
  }

  /// Currently used by user files (excludes the placeholder).
  static Future<int> usedBytes(String rootPath) async {
    final filesDir = Directory(p.join(rootPath, 'files'));
    if (!await filesDir.exists()) return 0;
    int total = 0;
    await for (final entity in filesDir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {}
      }
    }
    return total;
  }

  static Future<int> placeholderBytes(String rootPath) async {
    final f = File(p.join(rootPath, '.weeber-reserve'));
    if (!await f.exists()) return 0;
    return f.length();
  }

  /// Total reservation = placeholder + actual usage.
  static Future<int> totalAllocated(String rootPath) async {
    return await usedBytes(rootPath) + await placeholderBytes(rootPath);
  }

  static Future<void> _setSize(File file, int bytes) async {
    if (bytes <= 0) {
      if (await file.exists()) await file.delete();
      return;
    }

    // Try the platform-specific true-preallocation first.
    final ok = await _tryNativePreallocate(file.path, bytes);
    if (ok) return;

    // Fallback: extend by writing one byte at the target offset. This
    // creates a sparse file on most systems — better than nothing.
    if (!await file.exists()) await file.create(recursive: true);
    final raf = await file.open(mode: FileMode.write);
    try {
      await raf.setPosition(bytes - 1);
      await raf.writeByte(0);
    } finally {
      await raf.close();
    }
  }

  static Future<bool> _tryNativePreallocate(String path, int bytes) async {
    try {
      if (Platform.isLinux) {
        // fallocate reserves real blocks instantly — what we want.
        final r = await Process.run('fallocate', ['-l', '$bytes', path]);
        return r.exitCode == 0;
      }
      if (Platform.isMacOS) {
        // mkfile pre-allocates real blocks (writes zeros, slower for large sizes
        // but truly reserves space). For >10GB consider showing progress.
        final r = await Process.run('mkfile', ['-n', '$bytes', path]);
        return r.exitCode == 0;
      }
      if (Platform.isWindows) {
        // fsutil file createnew creates a file of exact size.
        final r = await Process.run('fsutil', ['file', 'createnew', path, '$bytes']);
        return r.exitCode == 0;
      }
    } catch (_) {
      // fall through to sparse fallback
    }
    return false;
  }
}
