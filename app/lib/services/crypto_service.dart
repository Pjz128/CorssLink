import 'dart:convert';
import 'dart:math';

import 'package:pinenacl/x25519.dart';

/// Wraps pinenacl NaCl box (Curve25519 + XSalsa20 + Poly1305) to match
/// the Go crosslink-poc/pairing wire format.
class CryptoService {
  late final PrivateKey _privateKey;

  CryptoService() {
    _privateKey = PrivateKey.generate();
  }

  /// The ephemeral keypair for this pairing session.
  PrivateKey get privateKey => _privateKey;
  PublicKey get publicKey => _privateKey.publicKey;

  /// Raw 32-byte public key.
  Uint8List get publicKeyBytes => publicKey.asTypedList;

  /// Base64-URL-encoded public key (matches Go's base64.URLEncoding).
  String get publicKeyBase64 => base64Url.encode(publicKeyBytes);

  /// Decrypt a long-term token received from an agent.
  ///
  /// Matches Go's pairing.KeyPair.DecryptToken:
  ///   senderPubKey (32 bytes), nonce (24 bytes), ciphertext → plaintext
  Uint8List decryptToken({
    required String senderPublicKey,
    required String nonce,
    required String ciphertext,
  }) {
    final senderPubKeyBytes =
        Uint8List.fromList(base64Url.decode(senderPublicKey));
    final nonceBytes = Uint8List.fromList(base64Url.decode(nonce));
    final ciphertextBytes = Uint8List.fromList(base64Url.decode(ciphertext));

    final senderPK = PublicKey(senderPubKeyBytes);
    final box = Box(myPrivateKey: _privateKey, theirPublicKey: senderPK);

    return box.decrypt(
      ByteList.withConstraint(ciphertextBytes,
          constraintLength: ciphertextBytes.length),
      nonce: nonceBytes,
    );
  }
}

/// Wraps pinenacl SecretBox (XSalsa20-Poly1305 symmetric encryption) for
/// encrypting device tokens at rest.  Matches Go's pairing.Store approach.
class SecretStore {
  final Uint8List _key;

  SecretStore._(this._key);

  /// Create a store with a random 32-byte master key.
  factory SecretStore.random() {
    final key = Uint8List(32);
    final rng = Random.secure();
    for (var i = 0; i < 32; i++) {
      key[i] = rng.nextInt(256);
    }
    return SecretStore._(key);
  }

  /// Create a store from a previously-saved base64 key.
  factory SecretStore.fromBase64(String encoded) {
    return SecretStore._(Uint8List.fromList(base64.decode(encoded)));
  }

  /// The master key, base64-encoded for storage in shared_preferences.
  String get keyBase64 => base64.encode(_key);

  /// Encrypt plaintext bytes. Returns an EncryptedMessage whose
  /// `.asTypedList` (or `.toList()`) can be serialised.
  Uint8List encrypt(Uint8List plaintext) {
    final box = SecretBox(_key);
    final result = box.encrypt(plaintext);
    // result.nonce + result.cipherText serialised as one blob
    return Uint8List.fromList([...result.nonce, ...result.cipherText]);
  }

  /// Decrypt a blob produced by [encrypt].
  Uint8List decrypt(Uint8List encrypted) {
    const nonceLen = 24;
    final nonce = Uint8List.fromList(encrypted.take(nonceLen).toList());
    final ct = Uint8List.fromList(encrypted.skip(nonceLen).toList());
    final box = SecretBox(_key);
    return box.decrypt(
      ByteList.withConstraint(ct, constraintLength: ct.length),
      nonce: nonce,
    );
  }
}
