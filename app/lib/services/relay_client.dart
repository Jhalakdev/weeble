import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../security/embedded_keys.dart';
import '../state/auth.dart';

/// HTTP client for the website-shaped VPS relay endpoints. Used by mobile
/// (iOS/Android) and demoted desktops — i.e. anywhere that ISN'T the active
/// host. All traffic goes VPS → tunnel hub → host, so the user's home
/// router needs zero configuration.
class RelayClient {
  RelayClient({required this.token});
  final String token;

  String get _base => EmbeddedSecrets.apiUrl;

  Future<RelayStats?> stats() async {
    try {
      final res = await http.get(
        Uri.parse('$_base/v1/relay/stats'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      return RelayStats(
        usedBytes: (j['used_bytes'] as int?) ?? 0,
        allocatedBytes: (j['allocated_bytes'] as int?) ?? 0,
        fileCount: (j['file_count'] as int?) ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// List live files. If [includeDeleted] is true, returns the trash
  /// (only soft-deleted entries) instead.
  Future<List<RelayFile>> listFiles({bool includeDeleted = false}) async {
    final qs = includeDeleted ? '?include_deleted=true' : '';
    final res = await http.get(
      Uri.parse('$_base/v1/relay/files$qs'),
      headers: {'Authorization': 'Bearer $token'},
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw RelayException(res.statusCode, res.body);
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final files = (j['files'] as List? ?? []).cast<Map<String, dynamic>>();
    return files.map(RelayFile.fromMap).toList();
  }

  /// Restore a soft-deleted file from the trash.
  Future<void> restoreFile(String id) async {
    final res = await http.post(
      Uri.parse('$_base/v1/relay/files/${Uri.encodeComponent(id)}/restore'),
      headers: {'Authorization': 'Bearer $token'},
    ).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw RelayException(res.statusCode, res.body);
  }

  /// Streamed download with per-chunk progress callback.
  Future<Uint8List> downloadFile({
    required String id,
    required void Function(int received, int total) onProgress,
  }) async {
    final req = http.Request('GET', Uri.parse('$_base/v1/relay/files/${Uri.encodeComponent(id)}'));
    req.headers['Authorization'] = 'Bearer $token';
    final streamed = await req.send().timeout(const Duration(seconds: 30));
    if (streamed.statusCode != 200) {
      final body = await streamed.stream.bytesToString();
      throw RelayException(streamed.statusCode, body);
    }
    final total = streamed.contentLength ?? 0;
    final chunks = <int>[];
    int received = 0;
    await for (final chunk in streamed.stream) {
      chunks.addAll(chunk);
      received += chunk.length;
      onProgress(received, total);
    }
    return Uint8List.fromList(chunks);
  }

  /// Streamed upload. The body buffer is sent as a single
  /// application/octet-stream POST. For files large enough to matter,
  /// use uploadStream below.
  Future<RelayFile> upload({
    required String name,
    required String mime,
    required Uint8List bytes,
    required void Function(int sent, int total) onProgress,
  }) async {
    final uri = Uri.parse('$_base/v1/relay/upload?name=${Uri.encodeQueryComponent(name)}&mime=${Uri.encodeQueryComponent(mime)}');
    final req = http.StreamedRequest('POST', uri);
    req.headers['Authorization'] = 'Bearer $token';
    req.headers['Content-Type'] = 'application/octet-stream';
    req.headers['Content-Length'] = bytes.length.toString();

    // Send in chunks so onProgress fires repeatedly.
    const chunkSize = 64 * 1024;
    () async {
      int sent = 0;
      for (int i = 0; i < bytes.length; i += chunkSize) {
        final end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
        final slice = bytes.sublist(i, end);
        req.sink.add(slice);
        sent += slice.length;
        onProgress(sent, bytes.length);
      }
      await req.sink.close();
    }();

    final res = await req.send().timeout(const Duration(minutes: 5));
    final body = await res.stream.bytesToString();
    if (res.statusCode != 200) {
      throw RelayException(res.statusCode, body);
    }
    final j = jsonDecode(body) as Map<String, dynamic>;
    return RelayFile(
      id: j['id'] as String,
      name: j['name'] as String,
      size: (j['size'] as int?) ?? bytes.length,
      mime: (j['mime'] as String?) ?? mime,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }

  /// Soft-delete by default (file moves to Trash). Pass hard=true to
  /// permanently wipe the blob — used by "Empty Trash".
  Future<void> deleteFile(String id, {bool hard = false}) async {
    final qs = hard ? '?hard=true' : '';
    final res = await http.delete(
      Uri.parse('$_base/v1/relay/files/${Uri.encodeComponent(id)}$qs'),
      headers: {'Authorization': 'Bearer $token'},
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw RelayException(res.statusCode, res.body);
    }
  }
}

class RelayStats {
  RelayStats({required this.usedBytes, required this.allocatedBytes, required this.fileCount});
  final int usedBytes;
  final int allocatedBytes;
  final int fileCount;
}

class RelayFile {
  RelayFile({required this.id, required this.name, required this.size, required this.mime, required this.createdAt});
  final String id;
  final String name;
  final int size;
  final String mime;
  final int createdAt;

  factory RelayFile.fromMap(Map<String, dynamic> m) => RelayFile(
        id: m['id'] as String,
        name: m['name'] as String,
        size: (m['size'] as int?) ?? 0,
        mime: (m['mime'] as String?) ?? 'application/octet-stream',
        createdAt: (m['created_at'] as int?) ?? 0,
      );
}

class RelayException implements Exception {
  RelayException(this.statusCode, this.body);
  final int statusCode;
  final String body;
  @override
  String toString() => 'RelayException($statusCode, $body)';
}

final relayClientProvider = Provider<RelayClient>((ref) {
  final token = ref.watch(authProvider).token ?? '';
  return RelayClient(token: token);
});
