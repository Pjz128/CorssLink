import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/pairing.dart';
import 'crypto_service.dart';

/// Persists paired-device credentials encrypted at rest.
///
/// Master key is stored in shared_preferences; device list is encrypted
/// with NaCl SecretBox before being written.
class DeviceStore {
  static const _keyDevices = 'crosslink.devices';
  static const _keyMaster = 'crosslink.master_key';

  late final SecretStore _secret;
  final SharedPreferences _prefs;

  DeviceStore._(this._prefs, this._secret);

  /// Load the store, creating a master key on first launch.
  static Future<DeviceStore> open() async {
    final prefs = await SharedPreferences.getInstance();
    final masterB64 = prefs.getString(_keyMaster);

    final SecretStore secret;
    if (masterB64 == null) {
      secret = SecretStore.random();
      await prefs.setString(_keyMaster, secret.keyBase64);
    } else {
      secret = SecretStore.fromBase64(masterB64);
    }
    return DeviceStore._(prefs, secret);
  }

  /// List all paired devices.
  List<PairedDevice> loadDevices() {
    final encrypted = _prefs.getString(_keyDevices);
    if (encrypted == null) return [];

    try {
      final bytes = base64.decode(encrypted);
      final decrypted = _secret.decrypt(bytes);
      final list = jsonDecode(utf8.decode(decrypted)) as List<dynamic>;
      return list
          .map((m) => PairedDevice.fromJson(m as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // Corrupted data — return empty
      return [];
    }
  }

  /// Save a newly paired device.
  Future<void> addDevice(PairedDevice device) async {
    final devices = loadDevices();
    // Replace if same deviceId
    devices.removeWhere((d) => d.deviceId == device.deviceId);
    devices.add(device);
    await _save(devices);
  }

  /// Remove a paired device.
  Future<void> removeDevice(String deviceId) async {
    final devices = loadDevices();
    devices.removeWhere((d) => d.deviceId == deviceId);
    await _save(devices);
  }

  Future<void> _save(List<PairedDevice> devices) async {
    final json =
        jsonEncode(devices.map((d) => d.toJson()).toList());
    final bytes = Uint8List.fromList(utf8.encode(json));
    final encrypted = _secret.encrypt(bytes);
    await _prefs.setString(_keyDevices, base64.encode(encrypted));
  }
}
