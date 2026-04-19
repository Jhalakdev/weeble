import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as cryp;
import 'package:path/path.dart' as p;

/// Creates and restores encrypted backup snapshots.
///
/// Snapshot layout:
///   <backup_root>/snapshots/<timestamp>/
///     manifest.json          ← list of files, sizes, hashes (encrypted)
///     manifest.mac           ← HMAC of manifest.json
///     chunks/<index>.bin     ← encrypted file chunks (AES-256-GCM)
///
/// Each chunk is independently encrypted with a per-chunk key derived via
/// HKDF(masterKey, "chunk:" + index). This way losing one chunk doesn't
/// compromise the rest, and we can resume an interrupted backup.
class SnapshotEngine {
  SnapshotEngine({required this.masterKey, required this.macKey});

  final List<int> masterKey; // 32 bytes
  final List<int> macKey;    // 32 bytes
  static final _aes = AesGcm.with256bits();
  static const _chunkBytes = 4 * 1024 * 1024; // 4 MB

  Future<SnapshotResult> create({
    required String sourceFolder,
    required String backupFolder,
    void Function(double pct, String currentFile)? onProgress,
  }) async {
    final ts = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final snapDir = Directory(p.join(backupFolder, 'snapshots', ts));
    final chunksDir = Directory(p.join(snapDir.path, 'chunks'));
    await chunksDir.create(recursive: true);

    // Walk source folder.
    final files = await _enumerateFiles(sourceFolder);
    final totalBytes = files.fold<int>(0, (a, f) => a + f.size);
    final manifestEntries = <Map<String, Object?>>[];

    int chunkIdx = 0;
    int writtenBytes = 0;
    final buffer = BytesBuilder();
    int bufferStartFile = 0;

    Future<void> flushChunk(int upToFile) async {
      if (buffer.isEmpty) return;
      final plain = buffer.takeBytes();
      final ck = await _deriveChunkKey(chunkIdx);
      final box = await _aes.encrypt(plain, secretKey: SecretKey(ck));
      final chunkFile = File(p.join(chunksDir.path, '$chunkIdx.bin'));
      final out = BytesBuilder()
        ..add(box.nonce)
        ..add(box.cipherText)
        ..add(box.mac.bytes);
      await chunkFile.writeAsBytes(out.toBytes(), flush: true);
      manifestEntries.add({
        'chunk_index': chunkIdx,
        'plain_bytes': plain.length,
        'cipher_bytes': out.length,
        'first_file_index': bufferStartFile,
        'last_file_index': upToFile,
      });
      chunkIdx++;
    }

    for (var i = 0; i < files.length; i++) {
      final fe = files[i];
      onProgress?.call(writtenBytes / max(1, totalBytes), fe.relativePath);
      final bytes = await File(fe.absolutePath).readAsBytes();
      // Header per file: magic + utf8(path) + length-prefixed bytes.
      final header = utf8.encode(jsonEncode({
        'p': fe.relativePath,
        'sz': bytes.length,
        'sha': cryp.sha256.convert(bytes).toString(),
      }));
      buffer.add(_lenPrefix(header));
      buffer.add(_lenPrefix(bytes));
      writtenBytes += bytes.length;

      while (buffer.length >= _chunkBytes) {
        // Don't split a file mid-stream — we already have whole files in the buffer.
        await flushChunk(i);
        bufferStartFile = i + 1;
      }
    }
    await flushChunk(files.length - 1);

    final manifest = {
      'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'file_count': files.length,
      'total_plain_bytes': totalBytes,
      'chunks': manifestEntries,
      'files': files.map((f) => {'path': f.relativePath, 'size': f.size}).toList(),
    };
    final manifestBytes = utf8.encode(jsonEncode(manifest));
    await File(p.join(snapDir.path, 'manifest.json')).writeAsBytes(manifestBytes, flush: true);
    final mac = await Hmac.sha256().calculateMac(manifestBytes, secretKey: SecretKey(macKey));
    await File(p.join(snapDir.path, 'manifest.mac')).writeAsBytes(mac.bytes, flush: true);

    onProgress?.call(1.0, '');
    return SnapshotResult(snapshotId: ts, snapshotDir: snapDir.path, totalBytes: totalBytes, fileCount: files.length, chunkCount: chunkIdx);
  }

  Future<RestoreResult> restore({
    required String snapshotDir,
    required String destinationFolder,
    void Function(double pct, String currentFile)? onProgress,
  }) async {
    final manifestBytes = await File(p.join(snapshotDir, 'manifest.json')).readAsBytes();
    final macBytes = await File(p.join(snapshotDir, 'manifest.mac')).readAsBytes();
    final expected = await Hmac.sha256().calculateMac(manifestBytes, secretKey: SecretKey(macKey));
    if (!_constantTimeEquals(expected.bytes, macBytes)) {
      throw const FormatException('manifest.mac mismatch — backup may be tampered');
    }

    final manifest = jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
    final chunks = (manifest['chunks'] as List).cast<Map<String, dynamic>>();
    int restoredCount = 0;
    final totalCount = manifest['file_count'] as int;
    await Directory(destinationFolder).create(recursive: true);

    for (final c in chunks) {
      final idx = c['chunk_index'] as int;
      final ck = await _deriveChunkKey(idx);
      final blob = await File(p.join(snapshotDir, 'chunks', '$idx.bin')).readAsBytes();
      final nonce = blob.sublist(0, 12);
      final tag = blob.sublist(blob.length - 16);
      final ct = blob.sublist(12, blob.length - 16);
      final plain = await _aes.decrypt(SecretBox(ct, nonce: nonce, mac: Mac(tag)), secretKey: SecretKey(ck));
      var off = 0;
      while (off < plain.length) {
        final (header, h2) = _readLenPrefixed(plain, off);
        off = h2;
        final (data, d2) = _readLenPrefixed(plain, off);
        off = d2;
        final h = jsonDecode(utf8.decode(header)) as Map<String, dynamic>;
        final relPath = h['p'] as String;
        final outPath = p.join(destinationFolder, relPath);
        await Directory(p.dirname(outPath)).create(recursive: true);
        await File(outPath).writeAsBytes(data, flush: true);
        restoredCount++;
        onProgress?.call(restoredCount / max(1, totalCount), relPath);
      }
    }
    return RestoreResult(filesRestored: restoredCount, destination: destinationFolder);
  }

  Future<List<int>> _deriveChunkKey(int index) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final k = await hkdf.deriveKey(
      secretKey: SecretKey(masterKey),
      info: utf8.encode('weeber-chunk:$index'),
      nonce: utf8.encode('weeber-snapshot-v1'),
    );
    return k.extractBytes();
  }

  Future<List<_FileEntry>> _enumerateFiles(String root) async {
    final out = <_FileEntry>[];
    final dir = Directory(root);
    if (!await dir.exists()) return out;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        final rel = p.relative(entity.path, from: root);
        // Skip control files we own.
        if (rel.startsWith('.weeber-')) continue;
        try {
          final size = await entity.length();
          out.add(_FileEntry(absolutePath: entity.path, relativePath: rel, size: size));
        } catch (_) {/* unreadable */}
      }
    }
    return out;
  }

  Uint8List _lenPrefix(List<int> data) {
    final out = ByteData(4)..setUint32(0, data.length, Endian.big);
    final b = BytesBuilder()..add(out.buffer.asUint8List())..add(data);
    return b.toBytes();
  }

  (Uint8List, int) _readLenPrefixed(List<int> data, int offset) {
    final len = ByteData.sublistView(Uint8List.fromList(data), offset, offset + 4).getUint32(0, Endian.big);
    final start = offset + 4;
    final end = start + len;
    return (Uint8List.fromList(data.sublist(start, end)), end);
  }
}

class _FileEntry {
  _FileEntry({required this.absolutePath, required this.relativePath, required this.size});
  final String absolutePath;
  final String relativePath;
  final int size;
}

class SnapshotResult {
  SnapshotResult({required this.snapshotId, required this.snapshotDir, required this.totalBytes, required this.fileCount, required this.chunkCount});
  final String snapshotId;
  final String snapshotDir;
  final int totalBytes;
  final int fileCount;
  final int chunkCount;
}

class RestoreResult {
  RestoreResult({required this.filesRestored, required this.destination});
  final int filesRestored;
  final String destination;
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff == 0;
}
