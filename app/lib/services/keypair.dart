import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'secure_storage.dart';

class DeviceKeypair {
  static const _kPrivKey = 'weeber_device_privkey';
  static const _kPubKey = 'weeber_device_pubkey';

  static Future<({String publicKeyB64, SimpleKeyPair keyPair})> getOrCreate(SecureStorage storage) async {
    final algo = Ed25519();
    final existing = await storage.read(key: _kPrivKey);
    final pubB64Existing = await storage.read(key: _kPubKey);

    if (existing != null && pubB64Existing != null) {
      final priv = base64Decode(existing);
      final keyPair = await algo.newKeyPairFromSeed(priv);
      stderr.writeln('[keypair] reusing existing: pubkey=${pubB64Existing.substring(0, 16)}…');
      return (publicKeyB64: pubB64Existing, keyPair: keyPair);
    }

    final keyPair = await algo.newKeyPair();
    final priv = await keyPair.extractPrivateKeyBytes();
    final pub = await keyPair.extractPublicKey();
    final pubB64 = base64Encode(pub.bytes);
    await storage.write(key: _kPrivKey, value: base64Encode(priv));
    await storage.write(key: _kPubKey, value: pubB64);
    stderr.writeln('[keypair] generated NEW pair: pubkey=${pubB64.substring(0, 16)}… (priv existed: ${existing != null}, pub existed: ${pubB64Existing != null})');
    return (publicKeyB64: pubB64, keyPair: keyPair);
  }
}
