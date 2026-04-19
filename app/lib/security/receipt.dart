import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import '../services/secure_storage.dart';
import 'embedded_keys.dart';

/// Verified, decoded license receipt.
class ReceiptPayload {
  ReceiptPayload({
    required this.accountId,
    required this.deviceId,
    required this.licenseId,
    required this.fingerprint,
    required this.plan,
    required this.expiresAt,
  });

  final String accountId;
  final String deviceId;
  final String licenseId;
  final String fingerprint;
  final String plan;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  /// True if expiry is within 24h — time to send a heartbeat.
  bool get nearExpiry => DateTime.now().isAfter(expiresAt.subtract(const Duration(hours: 24)));
}

class ReceiptVerificationException implements Exception {
  ReceiptVerificationException(this.reason);
  final String reason;
  @override
  String toString() => 'ReceiptVerificationException($reason)';
}

class ReceiptStore {
  static const _kReceipt = 'weeber_license_receipt';
  final SecureStorage storage;
  ReceiptStore(this.storage);

  Future<void> save(String receipt) async => storage.write(key: _kReceipt, value: receipt);
  Future<String?> load() => storage.read(key: _kReceipt);
  Future<void> clear() async => storage.delete(key: _kReceipt);

  /// Verifies the stored receipt against the embedded public key.
  /// Throws [ReceiptVerificationException] for any tamper / expiry / fingerprint mismatch.
  Future<ReceiptPayload> verify(String receipt, {required String expectedFingerprint}) async {
    final pem = EmbeddedSecrets.licensePublicKeyPem;
    if (pem.isEmpty) throw ReceiptVerificationException('no_embedded_key');

    JWT jwt;
    try {
      jwt = JWT.verify(receipt, RSAPublicKey(pem));
    } on JWTExpiredException {
      throw ReceiptVerificationException('expired');
    } catch (_) {
      throw ReceiptVerificationException('bad_signature');
    }

    final p = jwt.payload as Map<String, dynamic>;
    if (p['fp'] != expectedFingerprint) throw ReceiptVerificationException('fingerprint_mismatch');
    if (p['iss'] != 'weeber' || p['aud'] != 'weeber-app') throw ReceiptVerificationException('wrong_issuer');

    return ReceiptPayload(
      accountId: p['sub'] as String,
      deviceId: p['did'] as String,
      licenseId: p['lid'] as String,
      fingerprint: p['fp'] as String,
      plan: p['plan'] as String,
      expiresAt: DateTime.fromMillisecondsSinceEpoch((p['exp'] as int) * 1000),
    );
  }
}
