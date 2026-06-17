import 'dart:convert';

/// CrossLink DataChannel message types — matches Go poc/ollama/protocol.go.
class MsgType {
  static const chatRequest = 'chat-req';
  static const chatToken = 'chat-tok';
  static const chatDone = 'chat-done';
  static const chatError = 'chat-err';
  static const listModels = 'list-req';
  static const listResponse = 'list-res';
  static const status = 'status-req';
  static const statusResp = 'status-res';
  static const ping = 'ping';
  static const pong = 'pong';
}

/// Top-level envelope for all DataChannel messages.
class WireMessage {
  final String id;
  final int time;
  final String type;
  final Map<String, dynamic> body;

  WireMessage({
    required this.id,
    required this.time,
    required this.type,
    required this.body,
  });

  factory WireMessage.fromJson(Map<String, dynamic> json) {
    return WireMessage(
      id: json['id'] as String,
      time: json['time'] as int,
      type: json['type'] as String,
      body: json['body'] as Map<String, dynamic>? ?? {},
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'time': time,
        'type': type,
        'body': body,
      };

  static WireMessage create(String type, Map<String, dynamic> body) {
    return WireMessage(
      id: '${DateTime.now().millisecondsSinceEpoch}-${_counter++}',
      time: DateTime.now().millisecondsSinceEpoch,
      type: type,
      body: body,
    );
  }

  static int _counter = 0;
}

/// Payload for a chat request.
class ChatRequestBody {
  final String model;
  final List<ChatMessage> messages;

  ChatRequestBody({required this.model, required this.messages});

  Map<String, dynamic> toJson() => {
        'model': model,
        'messages': messages.map((m) => m.toJson()).toList(),
      };
}

/// A single chat message (role + content).
class ChatMessage {
  final String role;
  final String content;

  ChatMessage({required this.role, required this.content});

  Map<String, dynamic> toJson() => {'role': role, 'content': content};

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      role: json['role'] as String,
      content: json['content'] as String,
    );
  }
}

/// A model entry in the list response.
class ModelInfo {
  final String name;
  final String paramSize;
  final String quant;

  ModelInfo({required this.name, required this.paramSize, required this.quant});

  factory ModelInfo.fromJson(Map<String, dynamic> json) {
    return ModelInfo(
      name: json['name'] as String? ?? '',
      paramSize: json['paramSize'] as String? ?? '',
      quant: json['quant'] as String? ?? '',
    );
  }
}

/// Decode a JSON string into a WireMessage.
WireMessage decodeWireMessage(String raw) {
  return WireMessage.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
