import 'dart:convert';
import 'dart:io';
import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart' show RSAPrivateKey, RSAPublicKey;

/// Generates and caches a self-signed RSA certificate used by the host's
/// HTTPS file server. Clients pin the SHA-256 fingerprint of this cert
/// at pairing time.
class HostCertificate {
  HostCertificate({required this.certPath, required this.keyPath, required this.fingerprint});
  final String certPath;
  final String keyPath;
  final String fingerprint; // "sha256:<hex>"

  static Future<HostCertificate> getOrCreate(String storageRoot) async {
    final dir = Directory(p.join(storageRoot, '.tls'));
    await dir.create(recursive: true);
    final certPath = p.join(dir.path, 'host.crt');
    final keyPath = p.join(dir.path, 'host.key');

    if (!await File(certPath).exists() || !await File(keyPath).exists()) {
      await _generate(certPath: certPath, keyPath: keyPath);
    }
    final pem = await File(certPath).readAsString();
    final fp = _fingerprint(pem);
    return HostCertificate(certPath: certPath, keyPath: keyPath, fingerprint: fp);
  }

  static Future<void> _generate({required String certPath, required String keyPath}) async {
    final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
    final priv = pair.privateKey as RSAPrivateKey;
    final pub = pair.publicKey as RSAPublicKey;
    final dn = {'CN': 'weeber-host', 'O': 'Weeber'};
    final csr = X509Utils.generateRsaCsrPem(dn, priv, pub);
    final cert = X509Utils.generateSelfSignedCertificate(
      priv,
      csr,
      3650, // 10 years — pinned, won't be checked against a CA
    );
    await File(certPath).writeAsString(cert);
    await File(keyPath).writeAsString(CryptoUtils.encodeRSAPrivateKeyToPem(priv));
  }

  static String _fingerprint(String pem) {
    // Strip the PEM header/footer + newlines, base64-decode the DER,
    // and SHA-256 it.
    final lines = pem.split('\n').where((l) => !l.startsWith('-----') && l.trim().isNotEmpty);
    final der = base64.decode(lines.join());
    final digest = sha256.convert(der);
    return 'sha256:${digest.toString()}';
  }
}
