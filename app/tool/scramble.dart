// Build-time helper: takes plain values (API URL, public key PEM, cert pin)
// and emits a generated Dart file containing them XOR-scrambled into byte
// arrays. main.dart calls initEmbeddedSecrets() with these arrays at startup.
//
// Usage:
//   dart run tool/scramble.dart \
//     --api-url=https://api.weeber.app \
//     --pubkey-file=../license_pubkey.pem \
//     [--cert-fingerprint=AB:CD:...]
//
// Writes lib/security/embedded_secrets.g.dart.

import 'dart:io';
import 'dart:math';

void main(List<String> args) {
  final opts = <String, String>{};
  for (final a in args) {
    if (!a.startsWith('--')) continue;
    final eq = a.indexOf('=');
    if (eq < 0) continue;
    opts[a.substring(2, eq)] = a.substring(eq + 1);
  }

  final apiUrl = opts['api-url'] ?? '';
  final pubkeyFile = opts['pubkey-file'] ?? '';
  final certFp = opts['cert-fingerprint'] ?? '';

  if (apiUrl.isEmpty || pubkeyFile.isEmpty) {
    stderr.writeln('Usage: dart run tool/scramble.dart --api-url=... --pubkey-file=... [--cert-fingerprint=...]');
    exit(2);
  }

  final pubkey = File(pubkeyFile).readAsStringSync();
  final pubkeyPair = _scramble(pubkey);
  final apiUrlPair = _scramble(apiUrl);
  final certPair = _scramble(certFp);

  final out = StringBuffer();
  out.writeln('// GENERATED — do not edit. Run tool/scramble.dart to regenerate.');
  out.writeln('library;');
  out.writeln('');
  out.writeln('import "embedded_keys.dart";');
  out.writeln('');
  out.writeln('void applyEmbeddedSecrets() {');
  out.writeln('  initEmbeddedSecrets(');
  out.writeln('    pubKeyA: ${_lit(pubkeyPair.$1)},');
  out.writeln('    pubKeyB: ${_lit(pubkeyPair.$2)},');
  out.writeln('    apiUrlA: ${_lit(apiUrlPair.$1)},');
  out.writeln('    apiUrlB: ${_lit(apiUrlPair.$2)},');
  out.writeln('    pinA: ${_lit(certPair.$1)},');
  out.writeln('    pinB: ${_lit(certPair.$2)},');
  out.writeln('  );');
  out.writeln('}');

  final outFile = File('lib/security/embedded_secrets.g.dart');
  outFile.writeAsStringSync(out.toString());
  stdout.writeln('Wrote ${outFile.path} — embedded ${pubkey.length} byte pubkey + ${apiUrl.length} byte URL.');
}

(List<int>, List<int>) _scramble(String value) {
  final bytes = value.codeUnits;
  final rand = Random.secure();
  final mask = List<int>.generate(bytes.length, (_) => rand.nextInt(256));
  final scrambled = List<int>.generate(bytes.length, (i) => bytes[i] ^ mask[i]);
  return (scrambled, mask);
}

String _lit(List<int> bytes) {
  return 'const [${bytes.join(',')}]';
}
