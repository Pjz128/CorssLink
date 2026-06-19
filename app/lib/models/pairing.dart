import 'dart:convert';

/// QR code payload decoded from a crosslink://pair? URI.
class QRPayload {
  final int version;
  final String publicKey;
  final String serverUrl;
  final String peerId;
  final String pairToken; // extracted from serverUrl if HTTP v2

  QRPayload({
    required this.version,
    required this.publicKey,
    required this.serverUrl,
    required this.peerId,
    this.pairToken = '',
  });

  /// Parse a `crosslink://pair?<json>` URI into a QRPayload.
  factory QRPayload.fromUri(String uri) {
    final u = Uri.parse(uri);
    if (u.scheme != 'crosslink' || u.host != 'pair') {
      throw FormatException('Not a crosslink pairing URI: $uri');
    }
    final raw = Uri.decodeQueryComponent(u.query);
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final srv = map['srv'] as String;

    // Extract pair token from HTTP serverUrl (v2 format)
    String pairToken = '';
    if (srv.startsWith('http')) {
      final srvUri = Uri.parse(srv);
      pairToken = srvUri.queryParameters['token'] ?? '';
    }

    return QRPayload(
      version: map['v'] as int,
      publicKey: map['pk'] as String,
      serverUrl: srv,
      peerId: map['pid'] as String,
      pairToken: pairToken,
    );
  }

  /// Whether this QR represents an HTTP v2 agent.
  bool get isHttpV2 => serverUrl.startsWith('http');
}

/// Represents a paired device.
class PairedDevice {
  final String deviceId;
  final String deviceName;
  final String agentId;
  final String token;
  final DateTime pairedAt;
  final String serverUrl; // HTTP server URL (v2) or signal WS URL (v1)
  final String sessionToken; // v2 session token for Authorization header

  PairedDevice({
    required this.deviceId,
    required this.deviceName,
    required this.agentId,
    required this.token,
    required this.pairedAt,
    this.serverUrl = '',
    this.sessionToken = '',
  });

  factory PairedDevice.fromJson(Map<String, dynamic> json) {
    return PairedDevice(
      deviceId: json['deviceId'] as String,
      deviceName: json['deviceName'] as String,
      agentId: json['agentId'] as String,
      token: json['token'] as String,
      pairedAt:
          DateTime.fromMillisecondsSinceEpoch((json['pairedAt'] as int) * 1000),
      serverUrl: json['serverUrl'] as String? ?? '',
      sessionToken: json['sessionToken'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'agentId': agentId,
        'token': token,
        'pairedAt': pairedAt.millisecondsSinceEpoch ~/ 1000,
        'serverUrl': serverUrl,
        'sessionToken': sessionToken,
      };

  /// Whether this device was paired via HTTP v2 (vs WebSocket v1).
  bool get isHttpV2 => serverUrl.startsWith('http') && sessionToken.isNotEmpty;
}

/// Encrypted token received from the agent during pairing.
class EncryptedToken {
  final String senderPublicKey;
  final String nonce;
  final String ciphertext;

  EncryptedToken({
    required this.senderPublicKey,
    required this.nonce,
    required this.ciphertext,
  });

  factory EncryptedToken.fromJson(Map<String, dynamic> json) {
    return EncryptedToken(
      senderPublicKey: json['spk'] as String,
      nonce: json['n'] as String,
      ciphertext: json['c'] as String,
    );
  }
}

/// Long-term pairing token delivered by the agent.
class LongTermToken {
  final String token;
  final String agentId;
  final String deviceId;
  final String deviceName;
  final int createdAt;

  LongTermToken({
    required this.token,
    required this.agentId,
    required this.deviceId,
    required this.deviceName,
    required this.createdAt,
  });

  factory LongTermToken.fromJson(Map<String, dynamic> json) {
    return LongTermToken(
      token: json['token'] as String,
      agentId: json['agentId'] as String,
      deviceId: json['deviceId'] as String,
      deviceName: json['deviceName'] as String,
      createdAt: json['createdAt'] as int,
    );
  }

  Map<String, dynamic> toJson() => {
        'token': token,
        'agentId': agentId,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'createdAt': createdAt,
      };

  /// Convert to a [PairedDevice] for storage.
  PairedDevice toPairedDevice() => PairedDevice(
        deviceId: deviceId,
        deviceName: deviceName,
        agentId: agentId,
        token: token,
        pairedAt: DateTime.now(),
      );
}
