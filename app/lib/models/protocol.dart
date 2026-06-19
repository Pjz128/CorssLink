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
  // Agentic extensions (Claude Code, etc.)
  static const thinking = 'thinking';
  static const toolUse = 'tool-use';
  static const toolInput = 'tool-input';
  static const toolResult = 'tool-result';
  static const setModel = 'set-model';
  static const listAgents = 'list-agents';
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

/// Describes an available agent backend and its models.
class AgentInfo {
  final String type;
  final String label;
  final List<ModelInfo> models;

  AgentInfo({required this.type, required this.label, required this.models});

  factory AgentInfo.fromJson(Map<String, dynamic> json) {
    return AgentInfo(
      type: json['type'] as String? ?? '',
      label: json['label'] as String? ?? '',
      models: (json['models'] as List?)
              ?.map((m) => ModelInfo.fromJson(m as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

/// Payload for a chat request.
class ChatRequestBody {
  final String? agent; // backend selection (null = default)
  final String model;
  final List<ChatMessage> messages;

  ChatRequestBody({this.agent, required this.model, required this.messages});

  Map<String, dynamic> toJson() => {
        if (agent != null) 'agent': agent,
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

// ---- Agentic message body models ----

/// A tool call event from the agent.
class ToolCallEvent {
  final String id;
  final String name;
  final Map<String, dynamic>? input;

  ToolCallEvent({required this.id, required this.name, this.input});

  factory ToolCallEvent.fromJson(Map<String, dynamic> json) {
    return ToolCallEvent(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      input: json['input'] as Map<String, dynamic>?,
    );
  }
}

/// A tool result event from the agent.
class ToolResultEvent {
  final String id;
  final String name;
  final String output;
  final bool isError;

  ToolResultEvent({
    required this.id,
    required this.name,
    required this.output,
    this.isError = false,
  });

  factory ToolResultEvent.fromJson(Map<String, dynamic> json) {
    return ToolResultEvent(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      output: json['output'] as String? ?? '',
      isError: json['isError'] as bool? ?? false,
    );
  }
}

/// Decode a JSON string into a WireMessage.
WireMessage decodeWireMessage(String raw) {
  return WireMessage.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
