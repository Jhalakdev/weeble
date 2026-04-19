import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'secure_storage.dart';

/// Per-device Ed25519 keypair. Private key lives in our file-based
/// encrypted store (machine-bound; see [SecureStorage]).
/// Public key is shared with the backend during device registration so the
/// backend can verify signed requests later.
class DeviceKeypair {
  static const _kPrivKey = 'weeber_device_privkey';
  static const _kPubKey = 'weeber_device_pubkey';

  static Future<({String publicKeyB64, SimpleKeyPair keyPair})> getOrCreate(SecureStorage storage) async {
    final algo = Ed25519();
    final existing = await storage.read(key: _kPrivKey);
    if (existing != null) {
      final priv = base64Decode(existing);
      final pubB64 = await storage.read(key: _kPubKey);
      final keyPair = await algo.newKeyPairFromSeed(priv);
      return (publicKeyB64: pubB64!, keyPair: keyPair);
    }
    final keyPair = await algo.newKeyPair();
    final priv = await keyPair.extractPrivateKeyBytes();
    final pub = await keyPair.extractPublicKey();
    final pubB64 = base64Encode(pub.bytes);
    await storage.write(key: _kPrivKey, value: base64Encode(priv));
    await storage.write(key: _kPubKey, value: pubB64);
    return (publicKeyB64: pubB64, keyPair: keyPair);
  }
}
