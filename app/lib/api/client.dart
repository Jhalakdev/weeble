import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

class ApiException implements Exception {
  ApiException(this.code, this.statusCode);
  final String code;
  final int statusCode;
  @override
  String toString() => 'ApiException($code, $statusCode)';
}

class AuthResponse {
  AuthResponse({required this.token, this.refreshToken, required this.accountId, required this.plan, required this.status});
  final String token;                // short-lived access token
  final String? refreshToken;        // 90-day rotating refresh — null for older servers
  final String accountId;
  final String plan;
  final String status;
}

class TokenPair {
  TokenPair({required this.accessToken, required this.refreshToken});
  final String accessToken;
  final String refreshToken;
}

class DeviceRegistration {
  DeviceRegistration({required this.deviceId, required this.token, this.refreshToken});
  final String deviceId;
  final String token;
  final String? refreshToken;
}

class BillingStatus {
  BillingStatus({required this.plan, required this.status, required this.trialDaysRemaining});
  final String plan;
  final String status;
  final int trialDaysRemaining;
}

class WeeberApi {
  WeeberApi({required this.baseUrl, http.Client? client}) : _client = client ?? http.Client();
  final String baseUrl;
  final http.Client _client;

  String _platform() {
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'web';
  }

  Future<Map<String, dynamic>> _post(String path, {Map<String, dynamic>? body, String? token}) async {
    final res = await _client.post(
      Uri.parse('$baseUrl$path'),
      headers: {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      },
      body: body == null ? null : jsonEncode(body),
    );
    return _decode(res);
  }

  Future<Map<String, dynamic>> _get(String path, {String? token}) async {
    final res = await _client.get(
      Uri.parse('$baseUrl$path'),
      headers: {if (token != null) 'Authorization': 'Bearer $token'},
    );
    return _decode(res);
  }

  Map<String, dynamic> _decode(http.Response res) {
    final body = res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw ApiException(body['error']?.toString() ?? 'http_${res.statusCode}', res.statusCode);
    }
    return body;
  }

  Future<void> register(String email, String password) async {
    await _post('/v1/auth/register', body: {'email': email, 'password': password});
  }

  Future<AuthResponse> login(String email, String password) async {
    final json = await _post('/v1/auth/login', body: {'email': email, 'password': password});
    return AuthResponse(
      token: (json['access_token'] as String?) ?? json['token'] as String,
      refreshToken: json['refresh_token'] as String?,
      accountId: json['account_id'] as String,
      plan: json['plan'] as String,
      status: json['status'] as String,
    );
  }

  /// Rotate a refresh token → fresh {access, refresh} pair. The old
  /// refresh is invalidated server-side. Re-using it counts as theft
  /// and the whole family is revoked.
  Future<TokenPair?> refreshPair(String refreshToken) async {
    try {
      final json = await _post('/v1/auth/refresh', body: {'refresh_token': refreshToken});
      final access = (json['access_token'] as String?) ?? json['token'] as String?;
      final refresh = json['refresh_token'] as String?;
      if (access == null || refresh == null) return null;
      return TokenPair(accessToken: access, refreshToken: refresh);
    } on ApiException {
      return null;
    }
  }

  /// Revoke a refresh token (and its entire family) server-side.
  /// Safe to call even if the token is already revoked / unknown.
  Future<void> logout(String refreshToken) async {
    try {
      await _post('/v1/auth/logout', body: {'refresh_token': refreshToken});
    } catch (_) { /* best-effort */ }
  }

  Future<DeviceRegistration> registerDevice({
    required String token,
    required String name,
    required String pubkey,
    required String kind, // 'host' | 'client'
  }) async {
    final json = await _post('/v1/devices', token: token, body: {
      'kind': kind,
      'name': name,
      'platform': _platform(),
      'pubkey': pubkey,
    });
    return DeviceRegistration(
      deviceId: json['device_id'] as String,
      token: (json['access_token'] as String?) ?? json['token'] as String,
      refreshToken: json['refresh_token'] as String?,
    );
  }

  Future<BillingStatus> billingStatus(String token) async {
    final json = await _get('/v1/billing/status', token: token);
    return BillingStatus(
      plan: json['plan'] as String,
      status: json['status'] as String,
      trialDaysRemaining: json['trial_days_remaining'] as int,
    );
  }

  // ---- Devices

  Future<List<Map<String, dynamic>>> listDevices(String token) async {
    final json = await _get('/v1/devices', token: token);
    return (json['devices'] as List).cast<Map<String, dynamic>>();
  }

  Future<void> renameDevice({required String token, required String id, required String name}) async {
    final res = await _client.patch(
      Uri.parse('$baseUrl/v1/devices/$id'),
      headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
      body: jsonEncode({'name': name}),
    );
    _decode(res);
  }

  Future<void> revokeDevice({required String token, required String id}) async {
    final res = await _client.delete(
      Uri.parse('$baseUrl/v1/devices/$id'),
      headers: {'Authorization': 'Bearer $token'},
    );
    _decode(res);
  }

  /// Returns the announce response which includes:
  ///   - status: 'active' (we are the active host) or 'demoted' (kicked off)
  ///   - took_over_from: previous active host's device_id (or null)
  /// On 409 ('not_active_host'), call again with takeOver=true to claim the slot.
  Future<Map<String, dynamic>> announce({
    required String token,
    required String publicIp,
    required int port,
    required String reachability,
    required String certFingerprint,
    bool takeOver = false,
  }) async {
    return _post('/v1/devices/me/announce', token: token, body: {
      'public_ip': publicIp,
      'port': port,
      'reachability': reachability,
      'cert_fingerprint': certFingerprint,
      'take_over': takeOver,
    });
  }

  /// Account-level lookup: where is the active host right now?
  /// Phones use this instead of remembering a specific host device_id, so they
  /// keep working when the user swaps server machines.
  Future<Map<String, dynamic>> getActiveHost(String token) {
    return _get('/v1/accounts/me/active-host', token: token);
  }

  Future<Map<String, dynamic>> getEndpoint({required String token, required String hostId}) {
    return _get('/v1/devices/$hostId/endpoint', token: token);
  }

  // ---- Pairing

  Future<Map<String, dynamic>> createPairingToken(String token) {
    return _post('/v1/auth/pairing/create', token: token);
  }

  Future<Map<String, dynamic>> redeemPairingToken(String pairingToken) {
    return _post('/v1/auth/pairing/redeem', body: {'token': pairingToken});
  }

  // ---- Sessions

  Future<Map<String, dynamic>> issueSession({required String token, required String hostDeviceId}) {
    return _post('/v1/sessions/issue', token: token, body: {'host_device_id': hostDeviceId});
  }

  Future<Map<String, dynamic>> validateSession({required String token, required String sessionToken}) {
    return _post('/v1/sessions/validate', token: token, body: {'token': sessionToken});
  }

  // ---- Sync

  Future<void> postTombstones({required String token, required List<String> fileIds}) async {
    await _post('/v1/sync/tombstones', token: token, body: {'file_ids': fileIds});
  }

  // ---- Shares

  Future<Map<String, dynamic>> createShare({
    required String token,
    required String fileId,
    required String fileName,
    required String mime,
    int? sizeBytes,
    int? expiresInSeconds,
    int? maxDownloads,
  }) {
    return _post('/v1/shares', token: token, body: {
      'file_id': fileId,
      'file_name': fileName,
      'mime': mime,
      if (sizeBytes != null) 'size_bytes': sizeBytes,
      if (expiresInSeconds != null) 'expires_in_seconds': expiresInSeconds,
      if (maxDownloads != null) 'max_downloads': maxDownloads,
    });
  }

  Future<List<Map<String, dynamic>>> listShares(String token) async {
    final json = await _get('/v1/shares', token: token);
    return (json['shares'] as List).cast<Map<String, dynamic>>();
  }

  Future<void> revokeShare({required String token, required String shareToken}) async {
    final res = await _client.delete(
      Uri.parse('$baseUrl/v1/shares/$shareToken'),
      headers: {'Authorization': 'Bearer $token'},
    );
    _decode(res);
  }

  Future<Map<String, dynamic>> getTombstones({required String token, required String hostDeviceId, int since = 0}) {
    return _get('/v1/sync/tombstones?host_device_id=$hostDeviceId&since=$since', token: token);
  }
}
