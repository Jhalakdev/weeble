import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../security/embedded_keys.dart';
import '../state/auth.dart';

/// HTTP client for the website-shaped VPS relay endpoints. Used by mobile
/// (iOS/Android) and demoted desktops — anywhere that ISN'T the active
/// host. All traffic goes VPS → tunnel hub → host, so the user's home
/// router needs zero configuration.
///
/// Every request runs through _withAuth: reads the current access token
/// from authProvider, runs the request, and on HTTP 401 calls
/// AuthNotifier.refreshIfNeeded() to rotate to a fresh pair, then retries
/// exactly once. No user re-login needed when the 1-hour access token
/// expires — the 90-day refresh token heals it invisibly.
class RelayClient {
  RelayClient({required this.ref});
  final Ref ref;

  String get _base => EmbeddedSecrets.apiUrl;

  String? _currentToken() => ref.read(authProvider).token;

  /// Runs a request-producing closure with auth. On 401, refreshes
  /// the token and retries once. Caller's closure receives a fresh
  /// Bearer-header-ready token string each attempt.
  Future<http.Response> _withAuth(
    Future<http.Response> Function(String token) run,
  ) async {
    final token = _currentToken();
    if (token == null) throw RelayException(401, 'no_token');
    final r = await run(token);
    if (r.statusCode != 401) return r;
    final fresh = await ref.read(authProvider.notifier).refreshIfNeeded();
    if (fresh == null) return r;
    return run(fresh);
  }

  Map<String, String> _authHeaders(String token, [Map<String, String>? extra]) => {
        'Authorization': 'Bearer $token',
        ...?extra,
      };

  Future<RelayStats?> stats() async {
    try {
      final res = await _withAuth((t) => http
          .get(Uri.parse('$_base/v1/relay/stats'), headers: _authHeaders(t))
          .timeout(const Duration(seconds: 8)));
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

  /// List files in a folder. parent=null/empty = root. include_deleted
  /// returns the flat trash view across all folders.
  Future<RelayListResult> listFiles({bool includeDeleted = false, String? parent}) async {
    final qp = <String, String>{};
    if (includeDeleted) qp['include_deleted'] = 'true';
    if (parent != null && parent.isNotEmpty) qp['parent'] = parent;
    final qs = qp.isEmpty ? '' : '?${Uri(queryParameters: qp).query}';
    final res = await _withAuth((t) => http
        .get(Uri.parse('$_base/v1/relay/files$qs'), headers: _authHeaders(t))
        .timeout(const Duration(seconds: 15)));
    if (res.statusCode != 200) {
      throw RelayException(res.statusCode, res.body);
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final files = (j['files'] as List? ?? []).cast<Map<String, dynamic>>().map(RelayFile.fromMap).toList();
    final path = (j['path'] as List? ?? [])
        .cast<Map<String, dynamic>>()
        .map((m) => RelayCrumb(id: m['id'] as String, name: m['name'] as String))
        .toList();
    return RelayListResult(files: files, path: path);
  }

  Future<RelayFile> createFolder({required String name, String? parentId}) async {
    final body = jsonEncode({'name': name, if (parentId != null && parentId.isNotEmpty) 'parent_id': parentId});
    final res = await _withAuth((t) => http
        .post(
          Uri.parse('$_base/v1/relay/folders'),
          headers: _authHeaders(t, {'Content-Type': 'application/json'}),
          body: body,
        )
        .timeout(const Duration(seconds: 15)));
    if (res.statusCode != 200) throw RelayException(res.statusCode, res.body);
    return RelayFile.fromMap(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<void> bulkAction({required String action, required List<String> ids, String? parentId}) async {
    final body = jsonEncode({
      'action': action, 'ids': ids,
      if (parentId != null) 'parent_id': parentId,
    });
    final res = await _withAuth((t) => http
        .post(
          Uri.parse('$_base/v1/relay/files/bulk'),
          headers: _authHeaders(t, {'Content-Type': 'application/json'}),
          body: body,
        )
        .timeout(const Duration(seconds: 30)));
    if (res.statusCode != 200) throw RelayException(res.statusCode, res.body);
  }

  Future<void> copyFileTo({required String id, String? parentId}) async {
    final body = jsonEncode({if (parentId != null) 'parent_id': parentId});
    final res = await _withAuth((t) => http
        .post(
          Uri.parse('$_base/v1/relay/files/${Uri.encodeComponent(id)}/copy'),
          headers: _authHeaders(t, {'Content-Type': 'application/json'}),
          body: body,
        )
        .timeout(const Duration(minutes: 5)));
    if (res.statusCode != 200) throw RelayException(res.statusCode, res.body);
  }

  /// Restore a soft-deleted file from the trash.
  Future<void> restoreFile(String id) async {
    final res = await _withAuth((t) => http
        .post(
          Uri.parse('$_base/v1/relay/files/${Uri.encodeComponent(id)}/restore'),
          headers: _authHeaders(t),
        )
        .timeout(const Duration(seconds: 10)));
    if (res.statusCode != 200) throw RelayException(res.statusCode, res.body);
  }

  /// Streamed download with per-chunk progress callback.
  Future<Uint8List> downloadFile({
    required String id,
    required void Function(int received, int total) onProgress,
  }) async {
    Future<http.StreamedResponse> sendOnce(String token) {
      final req = http.Request('GET', Uri.parse('$_base/v1/relay/files/${Uri.encodeComponent(id)}'));
      req.headers.addAll(_authHeaders(token));
      return req.send().timeout(const Duration(seconds: 30));
    }

    final token = _currentToken();
    if (token == null) throw RelayException(401, 'no_token');
    var streamed = await sendOnce(token);
    if (streamed.statusCode == 401) {
      await streamed.stream.drain<void>();
      final fresh = await ref.read(authProvider.notifier).refreshIfNeeded();
      if (fresh != null) streamed = await sendOnce(fresh);
    }
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

  /// Streamed upload. Body sent as one application/octet-stream POST.
  Future<RelayFile> upload({
    required String name,
    required String mime,
    required Uint8List bytes,
    required void Function(int sent, int total) onProgress,
    String? parentId,
  }) async {
    final parent = (parentId != null && parentId.isNotEmpty) ? '&parent=${Uri.encodeQueryComponent(parentId)}' : '';
    final uri = Uri.parse('$_base/v1/relay/upload?name=${Uri.encodeQueryComponent(name)}&mime=${Uri.encodeQueryComponent(mime)}$parent');

    // Buffer the whole payload once so we can rebuild the StreamedRequest
    // on a 401 retry without re-reading the original source.
    Future<http.StreamedResponse> sendOnce(String token) async {
      final req = http.StreamedRequest('POST', uri);
      req.headers['Authorization'] = 'Bearer $token';
      req.headers['Content-Type'] = 'application/octet-stream';
      req.headers['Content-Length'] = bytes.length.toString();
      const chunkSize = 64 * 1024;
      // ignore: unawaited_futures
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
      return req.send().timeout(const Duration(minutes: 5));
    }

    final token = _currentToken();
    if (token == null) throw RelayException(401, 'no_token');
    var res = await sendOnce(token);
    if (res.statusCode == 401) {
      await res.stream.drain();
      final fresh = await ref.read(authProvider.notifier).refreshIfNeeded();
      if (fresh != null) res = await sendOnce(fresh);
    }
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
    final res = await _withAuth((t) => http
        .delete(
          Uri.parse('$_base/v1/relay/files/${Uri.encodeComponent(id)}$qs'),
          headers: _authHeaders(t),
        )
        .timeout(const Duration(seconds: 15)));
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
  RelayFile({required this.id, required this.name, required this.size, required this.mime, required this.createdAt, this.parentId});
  final String id;
  final String name;
  final int size;
  final String mime;
  final int createdAt;
  final String? parentId;

  bool get isFolder => mime == 'inode/directory';

  factory RelayFile.fromMap(Map<String, dynamic> m) => RelayFile(
        id: m['id'] as String,
        name: m['name'] as String,
        size: (m['size'] as int?) ?? 0,
        mime: (m['mime'] as String?) ?? 'application/octet-stream',
        createdAt: (m['created_at'] as int?) ?? 0,
        parentId: m['parent_id'] as String?,
      );
}

class RelayCrumb {
  RelayCrumb({required this.id, required this.name});
  final String id;
  final String name;
}

class RelayListResult {
  RelayListResult({required this.files, required this.path});
  final List<RelayFile> files;
  final List<RelayCrumb> path;
}

class RelayException implements Exception {
  RelayException(this.statusCode, this.body);
  final int statusCode;
  final String body;
  @override
  String toString() => 'RelayException($statusCode, $body)';
}

final relayClientProvider = Provider<RelayClient>((ref) => RelayClient(ref: ref));
