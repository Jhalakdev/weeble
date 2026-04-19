import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// Splits the 64-byte Argon2id output into a 32-byte key-encryption-key (KEK)
/// and a 32-byte HMAC key for marker authentication. Two distinct keys from
/// one derivation, so a leak of either doesn't compromise the other.
class KeySplit {
  KeySplit({required this.kek, required this.macKey});
  final List<int> kek;
  final List<int> macKey;

  static KeySplit fromArgon(List<int> argonOutput) {
    if (argonOutput.length != 64) throw ArgumentError('argon output must be 64 bytes');
    return KeySplit(kek: argonOutput.sublist(0, 32), macKey: argonOutput.sublist(32));
  }
}

/// Wraps the master encryption key with the KEK using AES-256-GCM.
class WrappedKey {
  WrappedKey({required this.ciphertext, required this.nonce, required this.mac});
  final List<int> ciphertext;
  final List<int> nonce;
  final List<int> mac;

  static final _aes = AesGcm.with256bits();

  /// Generates a fresh 32-byte master key + wraps it under the KEK.
  static Future<({List<int> masterKey, WrappedKey wrap})> generate(List<int> kek) async {
    final r = Random.secure();
    final master = Uint8List.fromList(List<int>.generate(32, (_) => r.nextInt(256)));
    final box = await _aes.encrypt(master, secretKey: SecretKey(kek));
    return (
      masterKey: master,
      wrap: WrappedKey(ciphertext: box.cipherText, nonce: box.nonce, mac: box.mac.bytes),
    );
  }

  /// Unwraps the master key using the KEK. Throws if KEK is wrong or
  /// the wrap was tampered with (GCM auth tag fails).
  Future<List<int>> unwrap(List<int> kek) async {
    final box = SecretBox(ciphertext, nonce: nonce, mac: Mac(mac));
    return await _aes.decrypt(box, secretKey: SecretKey(kek));
  }
}
