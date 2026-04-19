import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import '../api/client.dart';
import 'cert.dart';
import 'file_index.dart';
import 'file_storage.dart';

/// Authenticates incoming requests by validating the session token presented
/// in the `X-Weeber-Session` header against our backend. Caches results for
/// 5 minutes to avoid hammering the VPS.
class _SessionValidator {
  _SessionValidator({required this.api, required this.hostToken});

  final WeeberApi api;
  final String hostToken;
  final Map<String, ({DateTime cachedAt, Map<String, dynamic> info})> _cache = {};

  Future<Map<String, dynamic>?> validate(String sessionToken) async {
    final hit = _cache[sessionToken];
    if (hit != null && DateTime.now().difference(hit.cachedAt).inMinutes < 5) {
      return hit.info;
    }
    try {
      final res = await api.validateSession(token: hostToken, sessionToken: sessionToken);
      _cache[sessionToken] = (cachedAt: DateTime.now(), info: res);
      return res;
    } on ApiException {
      return null;
    }
  }
}

class HostServer {
  HostServer({
    required this.cert,
    required this.index,
    required this.storage,
    required this.api,
    required this.hostToken,
  });

  final HostCertificate cert;
  final FileIndex index;
  final FileStorage storage;
  final WeeberApi api;
  final String hostToken;

  HttpServer? _server;
  int? port;

  Future<int> start({int requestedPort = 0}) async {
    final ctx = SecurityContext()
      ..useCertificateChain(cert.certPath)
      ..usePrivateKey(cert.keyPath);
    final validator = _SessionValidator(api: api, hostToken: hostToken);

    final router = Router()
      ..get('/health', (Request _) => Response.ok(jsonEncode({'ok': true}), headers: _json))
      ..get('/files', (Request req) => _listFiles(req, validator))
      ..get('/files/<id>', (Request req, String id) => _downloadFile(req, validator, id))
      ..post('/files', (Request req) => _uploadFile(req, validator));

    final handler = const Pipeline().addMiddleware(_logRequests).addHandler(router.call);

    _server = await shelf_io.serve(
      handler,
      InternetAddress.anyIPv4,
      requestedPort,
      securityContext: ctx,
    );
    port = _server!.port;
    return port!;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<Response> _authed(Request req, _SessionValidator v) async {
    final token = req.headers['x-weeber-session'];
    if (token == null) return Response.unauthorized(jsonEncode({'error': 'no_session'}), headers: _json);
    final info = await v.validate(token);
    if (info == null) return Response.unauthorized(jsonEncode({'error': 'invalid_session'}), headers: _json);
    return Response.ok('');
  }

  Future<Response> _listFiles(Request req, _SessionValidator v) async {
    final guard = await _authed(req, v);
    if (guard.statusCode == 401) return guard;
    final parent = req.url.queryParameters['parent'];
    final entries = await index.list(parentId: parent);
    return Response.ok(
      jsonEncode({'files': entries.map((e) => e.toMap()).toList()}),
      headers: _json,
    );
  }

  Future<Response> _downloadFile(Request req, _SessionValidator v, String id) async {
    final guard = await _authed(req, v);
    if (guard.statusCode == 401) return guard;
    final entry = await index.get(id);
    if (entry == null || entry.deletedAt != null) {
      return Response.notFound(jsonEncode({'error': 'not_found'}), headers: _json);
    }
    try {
      final bytes = await storage.read(id);
      return Response.ok(
        bytes,
        headers: {
          'content-type': entry.mime,
          'content-length': bytes.length.toString(),
          'content-disposition': 'attachment; filename="${entry.name}"',
        },
      );
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': 'read_failed'}), headers: _json);
    }
  }

  /// POST /files — client (phone / browser) uploads a file to the host.
  /// Headers:
  ///   X-Weeber-Session: <token from VPS /v1/sessions/issue>
  ///   X-File-Name:      url-encoded original file name
  ///   X-File-Mime:      mime type
  /// Body: raw file bytes.
  /// Writes to host disk (encrypted at rest if encryption enabled) and indexes it.
  Future<Response> _uploadFile(Request req, _SessionValidator v) async {
    final guard = await _authed(req, v);
    if (guard.statusCode == 401) return guard;

    final fileName = Uri.decodeComponent(req.headers['x-file-name'] ?? 'untitled');
    final mime = req.headers['x-file-mime'] ?? 'application/octet-stream';
    final bytes = await req.read().expand((chunk) => chunk).toList();
    if (bytes.isEmpty) {
      return Response(400, body: jsonEncode({'error': 'empty_body'}), headers: _json);
    }

    final id = _ulid();
    try {
      await storage.write(id, bytes);
      await index.insert(FileEntry(
        id: id,
        name: fileName,
        parentId: null,
        size: bytes.length,
        mime: mime,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ));
      return Response.ok(
        jsonEncode({'id': id, 'name': fileName, 'size': bytes.length, 'mime': mime}),
        headers: _json,
      );
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': 'write_failed', 'detail': '$e'}), headers: _json);
    }
  }

  static int _randCtr = 0;
  static String _ulid() {
    final t = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final r = (DateTime.now().microsecondsSinceEpoch & 0xfffffff).toRadixString(36);
    return '$t-$r-${(++_randCtr).toRadixString(36).padLeft(4, "0")}';
  }
}

const _json = {'content-type': 'application/json'};

Middleware _logRequests = (Handler inner) {
  return (Request req) async {
    final sw = Stopwatch()..start();
    final res = await inner(req);
    // ignore: avoid_print
    print('[host] ${req.method} ${req.requestedUri.path} → ${res.statusCode} (${sw.elapsedMilliseconds}ms)');
    return res;
  };
};
