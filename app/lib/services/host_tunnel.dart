import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import '../security/embedded_keys.dart';
import '../state/auth.dart';
import '../state/config.dart';
import '../state/host_runtime.dart';
import 'file_index.dart';

/// Persistent outbound WebSocket from the host to our VPS.
///
/// Designed for the scenarios the user listed:
///   - Computer powered off → on: app re-launches → tunnel auto-connects.
///   - Router rebooted: WS dies → exponential-backoff reconnect → resumes.
///   - Switched networks (Wi-Fi → cellular hotspot): WS dies → reconnect on
///     the new network. The VPS sees a brand-new public IP, also fine.
///   - VPS restart: WS dies → reconnect when VPS is back.
///
/// Reconnect schedule: 1s, 2s, 4s, 8s, 16s, 30s, 30s… (capped). Never gives
/// up. Independent of any user action.
class HostTunnel {
  HostTunnel({required this.ref});
  final Ref ref;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnectTimer;
  Timer? _watchdog;
  int _backoffMs = 1000;
  bool _shouldRun = false;
  bool _connected = false;
  String? _lastError;

  // Queue + waiter for binary body frames. The VPS sends:
  //   {type:'req', hasBody:true} → binary frame → {type:'req-end'}
  // …but the binary frame can land BEFORE _handleRequest gets a chance to
  // start awaiting it. So _onFrame routes every binary into this queue,
  // and _waitForOneBinaryFrame pulls from the queue (or installs a waiter
  // if the queue is empty when called). This eliminates the race that was
  // causing iPhone uploads to hit "no_body" on the host.
  final List<Uint8List> _bodyQueue = [];
  Completer<Uint8List?>? _bodyWaiter;

  bool get connected => _connected;
  String? get lastError => _lastError;

  /// Convert http(s) base URL → ws(s) tunnel URL.
  String _wsUrl(String token) {
    final base = EmbeddedSecrets.apiUrl;
    final ws = base.replaceFirst(RegExp(r'^https?://'),
        base.startsWith('https://') ? 'wss://' : 'ws://');
    return '$ws/v1/tunnel/host?token=${Uri.encodeQueryComponent(token)}';
  }

  Future<void> start() async {
    _shouldRun = true;
    await _connectOnce();
  }

  Future<void> stop() async {
    _shouldRun = false;
    _reconnectTimer?.cancel();
    _watchdog?.cancel();
    await _sub?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _sub = null;
    _connected = false;
  }

  Future<void> _connectOnce() async {
    if (!_shouldRun) return;
    final auth = ref.read(authProvider);
    final token = auth.token;
    if (token == null) {
      _lastError = 'no_token';
      _scheduleReconnect();
      return;
    }
    final url = _wsUrl(token);
    try {
      // Use IOWebSocketChannel.connect on desktop/mobile (supports custom timeouts)
      final channel = IOWebSocketChannel.connect(
        Uri.parse(url),
        pingInterval: const Duration(seconds: 25),
      );
      _channel = channel;
      _connected = false; // will flip true on first frame
      _sub = channel.stream.listen(
        (data) => _onFrame(data),
        onDone: () { _onClosed('socket_done'); },
        onError: (e) { _onClosed('socket_error: $e'); },
        cancelOnError: false,
      );
      // Watchdog: if no frames in 90s, declare connection dead and reconnect.
      _resetWatchdog();
    } catch (e) {
      _lastError = 'connect_failed: $e';
      _scheduleReconnect();
    }
  }

  void _resetWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(const Duration(seconds: 90), () {
      _onClosed('watchdog_timeout');
    });
  }

  Future<void> _onFrame(dynamic data) async {
    _resetWatchdog();
    _connected = true;
    _backoffMs = 1000; // reset backoff on any successful frame

    // Binary frames are upload bodies for an in-flight request envelope.
    // Route them to the queue/waiter so _handleRequest picks them up,
    // regardless of arrival order vs the req text frame.
    if (data is List<int>) {
      final bytes = data is Uint8List ? data : Uint8List.fromList(data);
      final w = _bodyWaiter;
      if (w != null && !w.isCompleted) {
        _bodyWaiter = null;
        w.complete(bytes);
      } else {
        _bodyQueue.add(bytes);
      }
      return;
    }

    if (data is String) {
      Map<String, dynamic> msg;
      try { msg = jsonDecode(data) as Map<String, dynamic>; } catch (_) { return; }
      final type = msg['type'];
      if (type == 'hello') {
        // ignore: avoid_print
        print('[tunnel] hello from VPS');
        return;
      }
      if (type == 'ping') {
        _send(jsonEncode({'type': 'pong', 't': msg['t']}));
        return;
      }
      if (type == 'req') {
        // Don't await — handle the request concurrently so subsequent
        // text frames (req-end, next req) keep flowing through _onFrame.
        // ignore: unawaited_futures
        _handleRequest(msg);
        return;
      }
      if (type == 'req-end') {
        // (no body upload from VPS in our protocol — req-end is just a marker)
        return;
      }
    }
  }

  void _send(dynamic data) {
    try { _channel?.sink.add(data); } catch (_) {}
  }

  Future<void> _handleRequest(Map<String, dynamic> req) async {
    final id = req['id'] as String;
    final method = req['method'] as String;
    final path = req['path'] as String;
    final headers = (req['headers'] as Map?)?.cast<String, dynamic>() ?? {};
    final hasBody = req['hasBody'] == true;

    // For uploads we need to wait for binary chunks following this envelope.
    // For now: handle GET requests immediately; POST = body buffered (next
    // binary frame). To keep v1 simple we collect the next binary frame
    // synchronously here using an inline subscription pause-resume.
    Uint8List? bodyBytes;
    if (hasBody) {
      bodyBytes = await _waitForOneBinaryFrame();
    }

    try {
      final runtime = await ref.read(hostRuntimeProvider.future);
      if (runtime == null) {
        _sendResponse(id, 503, {'content-type': 'application/json'},
            utf8.encode(jsonEncode({'error': 'no_runtime'})));
        return;
      }

      if (method == 'GET' && path == '/stats') {
        final used = await runtime.index.totalSize();
        final files = await runtime.index.list();
        final cfg = ref.read(appConfigProvider);
        final json = jsonEncode({
          'used_bytes': used,
          'allocated_bytes': cfg.allocatedBytes ?? 0,
          'file_count': files.length,
        });
        _sendResponse(id, 200, {'content-type': 'application/json'}, utf8.encode(json));
        return;
      }
      if (method == 'GET' && path == '/storage-history') {
        // Returns the last N daily snapshots so the website can plot a real
        // "storage over time" line. Data is collected once per day by
        // HostLifecycle (see _snapshotStorageHistory).
        final history = await runtime.index.storageHistory(days: 30);
        final json = jsonEncode({'history': history});
        _sendResponse(id, 200, {'content-type': 'application/json'}, utf8.encode(json));
        return;
      }
      if (method == 'GET' && (path == '/files' || path.startsWith('/files?'))) {
        // ?include_deleted=true returns the trash; otherwise live entries only.
        final qIdx = path.indexOf('?');
        final includeDeleted = qIdx >= 0 && Uri.splitQueryString(path.substring(qIdx + 1))['include_deleted'] == 'true';
        final files = await runtime.index.list(includeDeleted: includeDeleted);
        // For trash view, only return entries that have actually been deleted.
        final filtered = includeDeleted ? files.where((f) => f.deletedAt != null).toList() : files;
        final json = jsonEncode({'files': filtered.map((e) => e.toMap()).toList()});
        _sendResponse(id, 200, {'content-type': 'application/json'}, utf8.encode(json));
        return;
      }
      if (method == 'POST' && path.startsWith('/files/') && path.endsWith('/restore')) {
        final fileId = Uri.decodeComponent(path.substring('/files/'.length, path.length - '/restore'.length));
        await runtime.index.restore(fileId);
        _sendResponse(id, 200, {'content-type': 'application/json'},
            utf8.encode(jsonEncode({'ok': true, 'id': fileId})));
        return;
      }
      if (method == 'GET' && path.startsWith('/files/')) {
        final fileId = Uri.decodeComponent(path.substring('/files/'.length));
        final entry = await runtime.index.get(fileId);
        if (entry == null || entry.deletedAt != null) {
          _sendResponse(id, 404, {'content-type': 'application/json'},
              utf8.encode(jsonEncode({'error': 'not_found'})));
          return;
        }
        final bytes = await runtime.storage.read(fileId);
        _sendResponse(id, 200, {
          'content-type': entry.mime,
          'content-length': bytes.length.toString(),
          'content-disposition': 'attachment; filename="${entry.name.replaceAll('"', '')}"',
        }, bytes);
        return;
      }
      if (method == 'POST' && path == '/files') {
        final fileName = Uri.decodeComponent(headers['x-file-name'] ?? 'untitled');
        final mime = headers['x-file-mime'] ?? 'application/octet-stream';
        if (bodyBytes == null) {
          _sendResponse(id, 400, {'content-type': 'application/json'},
              utf8.encode(jsonEncode({'error': 'no_body'})));
          return;
        }
        final newId = _ulid();
        await runtime.storage.write(newId, bodyBytes);
        await runtime.index.insert(FileEntry(
          id: newId,
          name: fileName,
          parentId: null,
          size: bodyBytes.length,
          mime: mime,
          createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        ));
        _sendResponse(id, 200, {'content-type': 'application/json'},
            utf8.encode(jsonEncode({'id': newId, 'name': fileName, 'size': bodyBytes.length, 'mime': mime})));
        return;
      }
      if (method == 'DELETE' && path.startsWith('/files/')) {
        // ?hard=true wipes the blob immediately (used by "Empty Trash").
        // Default = soft-delete: row stays with deleted_at, blob stays so
        // the user can restore from Trash.
        final qIdx = path.indexOf('?');
        final cleanPath = qIdx >= 0 ? path.substring(0, qIdx) : path;
        final hard = qIdx >= 0 && Uri.splitQueryString(path.substring(qIdx + 1))['hard'] == 'true';
        final fileId = Uri.decodeComponent(cleanPath.substring('/files/'.length));
        final entry = await runtime.index.get(fileId);
        if (entry == null) {
          _sendResponse(id, 404, {'content-type': 'application/json'},
              utf8.encode(jsonEncode({'error': 'not_found'})));
          return;
        }
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        if (hard) {
          await runtime.index.hardDelete(fileId);
          try { await runtime.storage.delete(fileId); } catch (_) {}
        } else {
          await runtime.index.softDelete(fileId, at: now);
        }
        _sendResponse(id, 200, {'content-type': 'application/json'},
            utf8.encode(jsonEncode({'ok': true, 'id': fileId, 'deleted_at': now, 'hard': hard})));
        return;
      }
      _sendResponse(id, 404, {'content-type': 'application/json'},
          utf8.encode(jsonEncode({'error': 'unknown_route', 'method': method, 'path': path})));
    } catch (e) {
      _sendResponse(id, 500, {'content-type': 'application/json'},
          utf8.encode(jsonEncode({'error': 'internal', 'detail': e.toString()})));
    }
  }

  void _sendResponse(String id, int status, Map<String, String> headers, List<int> body) {
    _send(jsonEncode({'type': 'res', 'id': id, 'status': status, 'headers': headers, 'hasBody': body.isNotEmpty}));
    if (body.isNotEmpty) {
      _send(Uint8List.fromList(body));
      _send(jsonEncode({'type': 'res-end', 'id': id}));
    }
  }

  // Pulls the next binary frame from the queue, or installs a one-shot
  // waiter for the next one to arrive. _onFrame routes every binary into
  // here, so the order of "req text" vs "binary body" doesn't matter.
  Future<Uint8List?> _waitForOneBinaryFrame() async {
    if (_bodyQueue.isNotEmpty) {
      return _bodyQueue.removeAt(0);
    }
    final c = Completer<Uint8List?>();
    _bodyWaiter = c;
    return c.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        if (identical(_bodyWaiter, c)) _bodyWaiter = null;
        return null;
      },
    );
  }

  void _onClosed(String reason) {
    _watchdog?.cancel();
    _connected = false;
    _lastError = reason;
    // ignore: avoid_print
    print('[tunnel] closed: $reason');
    _sub?.cancel();
    _sub = null;
    try { _channel?.sink.close(); } catch (_) {}
    _channel = null;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_shouldRun) return;
    _reconnectTimer?.cancel();
    final wait = _backoffMs;
    // ignore: avoid_print
    print('[tunnel] reconnecting in ${wait}ms');
    _reconnectTimer = Timer(Duration(milliseconds: wait), () => _connectOnce());
    _backoffMs = (_backoffMs * 2).clamp(1000, 30000);
  }

  static int _randCtr = 0;
  static String _ulid() {
    final t = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final r = (DateTime.now().microsecondsSinceEpoch & 0xfffffff).toRadixString(36);
    return '$t-$r-${(++_randCtr).toRadixString(36).padLeft(4, "0")}';
  }

}

final hostTunnelProvider = Provider<HostTunnel>((ref) => HostTunnel(ref: ref));
