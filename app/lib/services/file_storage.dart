import 'dart:io';
import 'package:path/path.dart' as p;
import 'encryption.dart';

/// Reads/writes blobs under <root>/files/<id-prefix>/<id>. Optionally encrypts
/// on the way in and decrypts on the way out.
class FileStorage {
  FileStorage({required this.root, required this.encryptionEnabled, required this.crypto});

  final String root;
  final bool encryptionEnabled;
  final FileCrypto crypto;

  String _pathFor(String id) {
    final prefix = id.length >= 2 ? id.substring(0, 2) : '00';
    return p.join(root, 'files', prefix, id);
  }

  Future<void> write(String id, List<int> plaintext) async {
    final path = _pathFor(id);
    await Directory(p.dirname(path)).create(recursive: true);
    final blob = encryptionEnabled ? await crypto.encrypt(id, plaintext) : plaintext;
    await File(path).writeAsBytes(blob, flush: true);
  }

  Future<List<int>> read(String id) async {
    final f = File(_pathFor(id));
    final blob = await f.readAsBytes();
    return encryptionEnabled ? await crypto.decrypt(id, blob) : blob;
  }

  Future<void> delete(String id) async {
    final f = File(_pathFor(id));
    if (await f.exists()) await f.delete();
  }

  Future<bool> exists(String id) => File(_pathFor(id)).exists();

  Future<int> size(String id) async {
    try {
      return await File(_pathFor(id)).length();
    } catch (_) {
      return 0;
    }
  }
}
