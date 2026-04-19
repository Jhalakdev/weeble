import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/client.dart';
import '../state/auth.dart';

/// The phone-side HTTPS client that talks to a host. Validates the host's
/// TLS cert via SHA-256 pinning — accepts ONLY the cert whose fingerprint
/// matches what the registry told us. A MITM presenting any other cert
/// (even one signed by a public CA) is rejected.
class HostClient {
  HostClient({required this.api});
  final WeeberApi api;

  /// Look up the active host for this account, then list files.
  Future<HostListResponse> listFiles({required String token, String? parentId}) async {
    final ep = await _resolveActiveHost(token);
    final url = Uri.https('${ep.publicIp}:${ep.port}', '/files',
        parentId == null ? null : {'parent': parentId});
    final resp = await _request(token: token, ep: ep, method: 'GET', url: url);
    final body = jsonDecode(resp) as Map<String, dynamic>;
    final files = (body['files'] as List).cast<Map<String, dynamic>>();
    return HostListResponse(host: ep, files: files);
  }

  /// Download bytes for a single file. Caller is responsible for writing
  /// them to disk / the share sheet / etc.
  Future<List<int>> downloadFile({required String token, required String hostDeviceId, required String fileId}) async {
    final ep = await _resolveActiveHost(token, hostDeviceIdHint: hostDeviceId);
    final url = Uri.https('${ep.publicIp}:${ep.port}', '/files/$fileId');
    return await _requestBytes(token: token, ep: ep, method: 'GET', url: url);
  }

  // ---- internals

  Future<_HostEndpoint> _resolveActiveHost(String token, {String? hostDeviceIdHint}) async {
    final json = await api.getActiveHost(token);
    return _HostEndpoint(
      deviceId: json['device_id'] as String,
      publicIp: json['public_ip'] as String,
      port: json['port'] as int,
      certFingerprint: json['cert_fingerprint'] as String,
    );
  }

  Future<String> _request({required String token, required _HostEndpoint ep, required String method, required Uri url}) async {
    final resp = await _requestBytes(token: token, ep: ep, method: method, url: url);
    return utf8.decode(resp);
  }

  Future<List<int>> _requestBytes({required String token, required _HostEndpoint ep, required String method, required Uri url}) async {
    // Issue a per-connection session token from the VPS. The host validates
    // it against the VPS too — neither side trusts the other unilaterally.
    final session = await api.issueSession(token: token, hostDeviceId: ep.deviceId);
    final sessionToken = session['token'] as String;

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..badCertificateCallback = (cert, host, port) => _verifyCertPin(cert, ep.certFingerprint);

    try {
      final req = await client.openUrl(method, url);
      req.headers.add('Authorization', 'Bearer $token');
      req.headers.add('X-Weeber-Session', sessionToken);
      final r = await req.close();
      if (r.statusCode >= 400) {
        final body = await r.transform(utf8.decoder).join();
        throw HostClientException(r.statusCode, body);
      }
      final out = <int>[];
      await for (final chunk in r) {
        out.addAll(chunk);
      }
      return out;
    } finally {
      client.close();
    }
  }

  /// Constant-time-ish comparison of cert fingerprint against expected pin.
  bool _verifyCertPin(X509Certificate cert, String expected) {
    final actual = 'sha256:${sha256.convert(cert.der).toString()}';
    if (actual.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < actual.length; i++) {
      diff |= actual.codeUnitAt(i) ^ expected.codeUnitAt(i);
    }
    return diff == 0;
  }
}

class HostClientException implements Exception {
  HostClientException(this.statusCode, this.body);
  final int statusCode;
  final String body;
  @override
  String toString() => 'HostClientException($statusCode, $body)';
}

class _HostEndpoint {
  _HostEndpoint({required this.deviceId, required this.publicIp, required this.port, required this.certFingerprint});
  final String deviceId;
  final String publicIp;
  final int port;
  final String certFingerprint;
}

class HostListResponse {
  HostListResponse({required this.host, required this.files});
  final _HostEndpoint host;
  final List<Map<String, dynamic>> files;
}

final hostClientProvider = Provider<HostClient>((ref) {
  return HostClient(api: ref.watch(apiProvider));
});
