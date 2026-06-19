import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/pairing.dart';
import '../models/protocol.dart';

/// HTTP+SSE client that replaces WebRTCService.
///
/// Connects directly to the Agent's HTTP server over LAN:
///   POST /api/chat  → SSE stream (Server-Sent Events)
///   GET  /api/agents → list available backends
class HttpService {
  final String baseUrl;
  final String sessionToken;

  HttpService({required this.baseUrl, required this.sessionToken});

  /// POST /api/chat → SSE stream mapped to [WireMessage] events.
  Stream<WireMessage> chatStream(
    String content, {
    String? agent,
    String? model,
  }) async* {
    final uri = Uri.parse('$baseUrl/api/chat');
    final body = jsonEncode({
      if (agent != null && agent.isNotEmpty) 'agent': agent,
      'model': model ?? '',
      'messages': [
        {'role': 'user', 'content': content},
      ],
    });

    final request = http.Request('POST', uri);
    request.headers['Content-Type'] = 'application/json';
    request.headers['Authorization'] = 'Bearer $sessionToken';
    request.body = body;

    try {
      final http.StreamedResponse response = await request.send();

      if (response.statusCode != 200) {
        final errBody = await response.stream.bytesToString();
        String errMsg = 'HTTP ${response.statusCode}';
        try {
          final decoded = jsonDecode(errBody);
          errMsg = decoded['error'] ?? errMsg;
        } catch (_) {}
        yield WireMessage(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          time: DateTime.now().millisecondsSinceEpoch,
          type: MsgType.chatError,
          body: {'code': response.statusCode, 'message': errMsg},
        );
        return;
      }

      // Parse SSE from the response stream
      yield* _parseSSE(response.stream);
    } catch (e) {
      yield WireMessage(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        time: DateTime.now().millisecondsSinceEpoch,
        type: MsgType.chatError,
        body: {'code': 0, 'message': e.toString()},
      );
    }
  }

  /// GET /api/agents → list of [AgentInfo].
  Future<List<AgentInfo>> fetchAgents() async {
    final uri = Uri.parse('$baseUrl/api/agents');
    final response = await http.get(uri, headers: {
      'Authorization': 'Bearer $sessionToken',
    });
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return (data['agents'] as List?)
              ?.map((a) => AgentInfo.fromJson(a as Map<String, dynamic>))
              .toList() ??
          [];
    }
    throw Exception('fetchAgents: HTTP ${response.statusCode}');
  }

  /// GET /health → true if server is reachable.
  Future<bool> healthCheck() async {
    try {
      final uri = Uri.parse('$baseUrl/health');
      final response = await http.get(uri);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    // http package client doesn't need explicit close
  }

  /// Parse SSE format: "event: <type>\ndata: <json>\n\n"
  Stream<WireMessage> _parseSSE(http.ByteStream byteStream) async* {
    final stream = byteStream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    String? eventType;
    final buffer = StringBuffer();

    await for (final line in stream) {
      if (line.startsWith('event: ')) {
        eventType = line.substring(7).trim();
      } else if (line.startsWith('data: ')) {
        buffer.write(line.substring(6));
      } else if (line.isEmpty && eventType != null) {
        final data = buffer.toString().trim();
        buffer.clear();
        if (data.isNotEmpty) {
          Map<String, dynamic> body;
          try {
            body = jsonDecode(data) as Map<String, dynamic>;
          } catch (_) {
            body = {'raw': data};
          }

          yield WireMessage(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            time: DateTime.now().millisecondsSinceEpoch,
            type: eventType!,
            body: body,
          );
        }
        eventType = null;
      }
    }
  }
}

/// Static helper for HTTP v2 pairing.
class HttpPairing {
  /// POST /api/pair → returns session info.
  static Future<PairedDevice> pair({
    required String serverUrl,
    required String pairToken,
    required String deviceName,
  }) async {
    final uri = Uri.parse('$serverUrl/api/pair');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'token': pairToken,
        'deviceName': deviceName,
      }),
    );

    if (response.statusCode != 200) {
      String err = 'Pairing failed (${response.statusCode})';
      try {
        final d = jsonDecode(response.body);
        err = d['error'] ?? err;
      } catch (_) {}
      throw Exception(err);
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return PairedDevice(
      deviceId: data['sessionId'] as String? ?? '',
      deviceName: deviceName,
      agentId: 'agent',
      token: data['sessionToken'] as String? ?? '',
      pairedAt: DateTime.now(),
      serverUrl: serverUrl,
      sessionToken: data['sessionToken'] as String? ?? '',
    );
  }
}
