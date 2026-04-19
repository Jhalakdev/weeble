import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Self-signed RSA-2048 certificate for the host's HTTPS server. Generated
/// by shelling out to `openssl` — which:
///   - ships with every macOS and Linux we care about
///   - produces PEM that Dart's `SecurityContext` accepts (unlike the
///     package-based route we tried first, which emitted PEM Dart refused
///     with `FormatException: Invalid character (at character 65)`)
///   - is battle-tested over 20+ years
///
/// Cached at <storageRoot>/.tls/host.{crt,key}. Clients pin the SHA-256
/// fingerprint of the cert at pairing time.
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

    // Probe: can Dart's TLS stack actually load this cert? If not, regen.
    // (Catches the case where the old basic_utils cert is still on disk.)
    try {
      SecurityContext()
        ..useCertificateChain(certPath)
        ..usePrivateKey(keyPath);
    } catch (_) {
      await _generate(certPath: certPath, keyPath: keyPath);
    }

    final pem = await File(certPath).readAsString();
    final fp = _fingerprint(pem);
    return HostCertificate(certPath: certPath, keyPath: keyPath, fingerprint: fp);
  }

  static Future<void> _generate({required String certPath, required String keyPath}) async {
    final opensslPath = await _findOpenssl();
    if (opensslPath == null) {
      throw StateError(
        'openssl not found on PATH — cannot generate TLS certificate. '
        'Install openssl (it ships with macOS/Linux; on Windows use Git Bash or WSL).',
      );
    }

    // One-shot: generate key + self-signed cert in a single openssl req call.
    // -nodes        → don't encrypt the private key (no passphrase prompt)
    // -newkey rsa:2048
    // -x509         → self-signed, not a CSR
    // -days 3650    → 10 years (we pin the fingerprint so expiry is moot)
    // -subj         → non-interactive DN
    // -addext       → add SAN so modern TLS libs accept it for localhost
    final result = await Process.run(opensslPath, [
      'req',
      '-x509',
      '-nodes',
      '-newkey', 'rsa:2048',
      '-keyout', keyPath,
      '-out', certPath,
      '-days', '3650',
      '-subj', '/CN=weeber-host/O=Weeber',
      '-addext', 'subjectAltName=DNS:weeber-host,DNS:localhost,IP:127.0.0.1',
    ]);

    if (result.exitCode != 0) {
      throw StateError('openssl cert generation failed: ${result.stderr}');
    }

    // POSIX: lock private key perms
    if (!Platform.isWindows) {
      await Process.run('chmod', ['600', keyPath]);
    }
  }

  static Future<String?> _findOpenssl() async {
    final candidates = Platform.isWindows
        ? ['openssl', 'openssl.exe']
        : ['/usr/bin/openssl', '/opt/homebrew/bin/openssl', '/usr/local/bin/openssl', 'openssl'];
    for (final path in candidates) {
      try {
        final r = await Process.run(path, ['version']);
        if (r.exitCode == 0) return path;
      } catch (_) {}
    }
    return null;
  }

  static String _fingerprint(String pem) {
    // Strip headers + every form of whitespace, decode base64 to DER, sha256.
    final cleaned = pem
        .replaceAll(RegExp(r'-----BEGIN [^-]+-----'), '')
        .replaceAll(RegExp(r'-----END [^-]+-----'), '')
        .replaceAll(RegExp(r'\s'), '');
    final der = base64.decode(cleaned);
    final digest = sha256.convert(der);
    return 'sha256:${digest.toString()}';
  }
}
