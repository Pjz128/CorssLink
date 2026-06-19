// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/pairing.dart';
import 'crypto_service.dart';

/// Result of a pairing handshake.
enum PairingStatus {
  connecting,
  requestSent,
  accepted,
  rejected,
  timeout,
  error,
}

/// Manages the client-side pairing flow over the CrossLink signal server.
class PairingService {
  final CryptoService _crypto;
  final String _deviceId;
  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  PairingService({required CryptoService crypto, required String deviceId})
      : _crypto = crypto,
        _deviceId = deviceId;

  /// Execute the full pairing handshake.
  ///
  /// [onStatus] receives status updates for UI display.
  /// Returns the decrypted [LongTermToken] on success, or `null` on failure.
  Future<LongTermToken?> pair(
    QRPayload qr,
    String deviceName, {
    void Function(PairingStatus status, String detail)? onStatus,
  }) async {
    final signalUrl = _buildSignalUrl(qr.serverUrl, _deviceId);
    onStatus?.call(PairingStatus.connecting, signalUrl);

    final completer = Completer<LongTermToken?>();

    try {
      _channel = WebSocketChannel.connect(Uri.parse(signalUrl));
      await _channel!.ready;

      _sub = _channel!.stream.listen(
        (data) => _onMessage(data, qr.peerId, completer, onStatus),
        onError: (e) {
          if (!completer.isCompleted) {
            onStatus?.call(PairingStatus.error, 'Connection error: $e');
            completer.complete(null);
          }
        },
        onDone: () {
          if (!completer.isCompleted) {
            onStatus?.call(PairingStatus.error, 'Server closed connection');
            completer.complete(null);
          }
        },
      );

      // Send pairing-request
      onStatus?.call(PairingStatus.requestSent,
          'Requesting pairing with ${qr.peerId}...');

      final req = {
        'type': 'pairing-request',
        'from': _deviceId,
        'to': qr.peerId,
        'publicKey': _crypto.publicKeyBase64,
        'deviceName': deviceName,
      };
      _channel!.sink.add(jsonEncode(req));

      // 30-second timeout
      final result = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          onStatus?.call(PairingStatus.timeout, 'Pairing timed out');
          return null;
        },
      );
      return result;
    } catch (e) {
      if (!completer.isCompleted) {
        onStatus?.call(PairingStatus.error, '$e');
      }
      return null;
    } finally {
      _sub?.cancel();
      _channel?.sink.close();
    }
  }

  void _onMessage(
    dynamic data,
    String expectedAgentId,
    Completer<LongTermToken?> completer,
    void Function(PairingStatus, String)? onStatus,
  ) {
    try {
      final msg = jsonDecode(data as String) as Map<String, dynamic>;
      final type = msg['type'] as String?;
      final from = msg['from'] as String?;

      switch (type) {
        case 'pairing-accepted':
          if (from != expectedAgentId) return;
          final allowed = msg['allowed'] as bool? ?? false;
          if (!allowed) {
            onStatus?.call(PairingStatus.rejected, 'Agent denied pairing');
            completer.complete(null);
            return;
          }
          onStatus?.call(PairingStatus.accepted, 'Decrypting token...');
          final token = _decryptToken(msg['token'] as String? ?? '');
          completer.complete(token);
          break;

        case 'pairing-rejected':
          if (from != expectedAgentId) return;
          onStatus?.call(PairingStatus.rejected, 'Agent denied pairing');
          completer.complete(null);
          break;

        default:
          // Ignore non-pairing messages (e.g. ping/pong)
          break;
      }
    } catch (e) {
      print('[pairing] onMessage error: $e');
    }
  }

  LongTermToken? _decryptToken(String tokenJson) {
    if (tokenJson.isEmpty) return null;

    try {
      final encMap = jsonDecode(tokenJson) as Map<String, dynamic>;
      final senderPk = encMap['spk'] as String? ?? '';
      final nonce = encMap['n'] as String? ?? '';
      final ct = encMap['c'] as String? ?? '';

      final plaintext = _crypto.decryptToken(
        senderPublicKey: senderPk,
        nonce: nonce,
        ciphertext: ct,
      );

      final lt = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
      return LongTermToken.fromJson(lt);
    } catch (e) {
      print('[pairing] decrypt failed: $e');
      return null;
    }
  }

  /// Build WebSocket URL from a signal server base URL and peer ID.
  String _buildSignalUrl(String baseUrl, String peerId) {
    // baseUrl is e.g. "ws://localhost:18080"
    final clean = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return '$clean/ws?peer=$peerId';
  }

  /// Release resources.
  void dispose() {
    _sub?.cancel();
    _channel?.sink.close();
  }
}
