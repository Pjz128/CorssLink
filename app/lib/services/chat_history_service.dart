import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// A single chat message record.
class ChatRecord {
  final String role; // 'user', 'assistant', 'error'
  final String content;
  final int time;

  ChatRecord({required this.role, required this.content, required this.time});

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        'time': time,
      };

  factory ChatRecord.fromJson(Map<String, dynamic> json) {
    return ChatRecord(
      role: json['role'] as String,
      content: json['content'] as String,
      time: json['time'] as int,
    );
  }
}

/// A named conversation session tied to one device.
class Session {
  final String id;
  final String deviceId;
  String title; // auto-generated from first user message
  final List<ChatRecord> messages;
  final int createdAt;
  int updatedAt;

  Session({
    required this.id,
    required this.deviceId,
    required this.title,
    required this.messages,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'deviceId': deviceId,
        'title': title,
        'messages': messages.map((m) => m.toJson()).toList(),
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  factory Session.fromJson(Map<String, dynamic> json) {
    return Session(
      id: json['id'] as String,
      deviceId: json['deviceId'] as String,
      title: json['title'] as String? ?? '新对话',
      messages: (json['messages'] as List)
          .map((m) => ChatRecord.fromJson(m as Map<String, dynamic>))
          .toList(),
      createdAt: json['createdAt'] as int,
      updatedAt: json['updatedAt'] as int,
    );
  }

  String get lastPreview {
    if (messages.isEmpty) return '';
    final last = messages.last;
    final prefix = last.role == 'user' ? '你: ' : '';
    final text = last.content.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ');
    final preview = '$prefix$text';
    return preview.length > 50 ? '${preview.substring(0, 50)}...' : preview;
  }
}

/// Persistent multi-session chat history per device.
class ChatHistoryService {
  static const _indexKey = 'crosslink.sessions.idx';

  final SharedPreferences _prefs;

  ChatHistoryService._(this._prefs);

  static Future<ChatHistoryService> open() async {
    final prefs = await SharedPreferences.getInstance();
    return ChatHistoryService._(prefs);
  }

  String _sessionKey(String id) => 'crosslink.session.$id';

  /// Load all session IDs for a device, sorted by updatedAt descending.
  List<String> listSessions(String deviceId) {
    final raw = _prefs.getString(_indexKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final all = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      all.sort((a, b) => (b['updatedAt'] as int).compareTo(a['updatedAt'] as int));
      return all
          .where((e) => e['deviceId'] == deviceId)
          .map((e) => e['id'] as String)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Load a session by ID.
  Session? load(String sessionId) {
    final raw = _prefs.getString(_sessionKey(sessionId));
    if (raw == null || raw.isEmpty) return null;
    try {
      return Session.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Save a session.
  Future<void> save(Session session) async {
    session.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _prefs.setString(_sessionKey(session.id), jsonEncode(session.toJson()));
    _updateIndex(session);
  }

  /// Delete a session.
  Future<void> delete(String sessionId) async {
    await _prefs.remove(_sessionKey(sessionId));
    _removeFromIndex(sessionId);
  }

  /// Create a new empty session.
  Session create(String deviceId) {
    final id = 's${DateTime.now().millisecondsSinceEpoch}-${_randomHex(4)}';
    final now = DateTime.now().millisecondsSinceEpoch;
    return Session(
      id: id,
      deviceId: deviceId,
      title: '新对话',
      messages: [],
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Search sessions for a device by query string (matches title or message content).
  List<String> searchSessions(String deviceId, String query) {
    if (query.isEmpty) return listSessions(deviceId);
    final lower = query.toLowerCase();
    return listSessions(deviceId).where((sid) {
      final s = load(sid);
      if (s == null) return false;
      if (s.title.toLowerCase().contains(lower)) return true;
      return s.messages.any((m) => m.content.toLowerCase().contains(lower));
    }).toList();
  }

  /// Auto-title: uses first non-empty user message.
  String autoTitle(String msg) {
    final clean = msg.replaceAll('\n', ' ').trim();
    return clean.length > 30 ? '${clean.substring(0, 30)}...' : clean;
  }

  // ---- index helpers ----

  void _updateIndex(Session session) {
    final raw = _prefs.getString(_indexKey);
    List<Map<String, dynamic>> all;
    if (raw != null && raw.isNotEmpty) {
      try {
        all = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      } catch (_) {
        all = [];
      }
    } else {
      all = [];
    }
    all.removeWhere((e) => e['id'] == session.id);
    all.add({
      'id': session.id,
      'deviceId': session.deviceId,
      'updatedAt': session.updatedAt,
    });
    _prefs.setString(_indexKey, jsonEncode(all));
  }

  void _removeFromIndex(String sessionId) {
    final raw = _prefs.getString(_indexKey);
    if (raw == null || raw.isEmpty) return;
    try {
      var all = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      all.removeWhere((e) => e['id'] == sessionId);
      _prefs.setString(_indexKey, jsonEncode(all));
    } catch (_) {}
  }

  String _randomHex(int len) {
    const chars = '0123456789abcdef';
    final rng = Random();
    return List.generate(len, (_) => chars[rng.nextInt(16)]).join();
  }
}
