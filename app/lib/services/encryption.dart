import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'secure_storage.dart';

/// Per-account master key, stored via our cross-platform [SecureStorage].
/// All file content keys are derived from this via HKDF(masterKey, fileId).
///
/// File-on-disk layout: [12-byte nonce][ciphertext][16-byte GCM MAC tag].
class FileCrypto {
  static const _kMasterKey = 'weeber_master_key';
  static final _algo = AesGcm.with256bits();

  final SecureStorage _storage;
  SecretKey? _master;

  FileCrypto(this._storage);

  Future<SecretKey> _getMaster() async {
    if (_master != null) return _master!;
    final existing = await _storage.read(key: _kMasterKey);
    if (existing != null) {
      _master = SecretKey(base64Decode(existing));
      return _master!;
    }
    final newKey = await _algo.newSecretKey();
    final bytes = await newKey.extractBytes();
    await _storage.write(key: _kMasterKey, value: base64Encode(bytes));
    _master = newKey;
    return _master!;
  }

  Future<SecretKey> _deriveFileKey(String fileId) async {
    final master = await _getMaster();
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    return hkdf.deriveKey(
      secretKey: master,
      info: utf8.encode('weeber-file:$fileId'),
      nonce: utf8.encode('weeber-v1'),
    );
  }

  /// Encrypts [plaintext] for a file with the given [fileId].
  /// Returns the on-disk blob: nonce || ciphertext || tag.
  Future<Uint8List> encrypt(String fileId, List<int> plaintext) async {
    final key = await _deriveFileKey(fileId);
    final box = await _algo.encrypt(plaintext, secretKey: key);
    final out = BytesBuilder()
      ..add(box.nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.toBytes();
  }

  /// Decrypts an on-disk blob produced by [encrypt].
  Future<Uint8List> decrypt(String fileId, List<int> blob) async {
    if (blob.length < 28) throw const FormatException('blob too short');
    final key = await _deriveFileKey(fileId);
    final nonce = blob.sublist(0, 12);
    final tag = blob.sublist(blob.length - 16);
    final ct = blob.sublist(12, blob.length - 16);
    final plain = await _algo.decrypt(
      SecretBox(ct, nonce: nonce, mac: Mac(tag)),
      secretKey: key,
    );
    return Uint8List.fromList(plain);
  }
}
