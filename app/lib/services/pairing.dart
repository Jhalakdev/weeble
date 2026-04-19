import 'dart:convert';

/// Wraps a JSON payload that goes inside the QR code shown by the host.
/// Includes everything a fresh client needs to claim the token and discover
/// the host afterwards.
class PairingPayload {
  PairingPayload({
    required this.token,
    required this.apiUrl,
    required this.hostDeviceId,
    required this.hostName,
    required this.expiresAt,
  });

  final String token;
  final String apiUrl;
  final String hostDeviceId;
  final String hostName;
  final int expiresAt;

  String encode() => jsonEncode({
        'v': 1,
        'token': token,
        'api': apiUrl,
        'host_id': hostDeviceId,
        'host_name': hostName,
        'exp': expiresAt,
      });

  static PairingPayload? tryDecode(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      if (m['v'] != 1) return null;
      return PairingPayload(
        token: m['token'] as String,
        apiUrl: m['api'] as String,
        hostDeviceId: m['host_id'] as String,
        hostName: m['host_name'] as String,
        expiresAt: m['exp'] as int,
      );
    } catch (_) {
      return null;
    }
  }

  bool get expired => DateTime.now().millisecondsSinceEpoch ~/ 1000 >= expiresAt;
}
