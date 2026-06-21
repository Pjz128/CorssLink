import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persistent app settings stored in shared_preferences.
class SettingsService {
  static const _keyServerUrl = 'crosslink.server_url';
  static const _keyModel = 'crosslink.model';
  static const _keyAgentId = 'crosslink.agent_id';
  static const _keyThemeColor = 'crosslink.theme_color';

  static const defaultServerUrl = 'http://crosslink.cyou:18080';
  static const defaultModel = 'deepseek-chat';
  static const defaultAgentId = 'agent-ollama-pc';
  static const defaultThemeColor = 0xFF1a1a2e;

  /// Notifies listeners when the theme color changes so the app can rebuild.
  static final themeNotifier = ValueNotifier<Color>(const Color(defaultThemeColor));

  final SharedPreferences _prefs;

  SettingsService._(this._prefs);

  static Future<SettingsService> open() async {
    final prefs = await SharedPreferences.getInstance();
    final svc = SettingsService._(prefs);
    // Sync notifier with persisted value
    themeNotifier.value = svc.themeColor;
    return svc;
  }

  String get serverUrl => _prefs.getString(_keyServerUrl) ?? defaultServerUrl;
  set serverUrl(String v) => _prefs.setString(_keyServerUrl, v);

  String get model => _prefs.getString(_keyModel) ?? defaultModel;
  set model(String v) => _prefs.setString(_keyModel, v);

  String get agentId => _prefs.getString(_keyAgentId) ?? defaultAgentId;
  set agentId(String v) => _prefs.setString(_keyAgentId, v);

  Color get themeColor => Color(_prefs.getInt(_keyThemeColor) ?? defaultThemeColor);
  set themeColor(Color v) {
    _prefs.setInt(_keyThemeColor, v.toARGB32());
    themeNotifier.value = v;
  }
}
