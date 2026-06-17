import 'package:flutter/material.dart';
import '../models/pairing.dart';
import '../models/protocol.dart';
import '../services/device_store.dart';
import '../services/settings_service.dart';
import '../services/webrtc_service.dart';
import 'dart:convert';
import 'dart:async';

class AgentDetailScreen extends StatefulWidget {
  final PairedDevice device;
  final DeviceStore store;
  final SettingsService settings;

  const AgentDetailScreen({
    super.key,
    required this.device,
    required this.store,
    required this.settings,
  });

  @override
  State<AgentDetailScreen> createState() => _AgentDetailScreenState();
}

class _AgentDetailScreenState extends State<AgentDetailScreen> {
  String _agentName = '';
  bool _connected = false;
  bool _checking = true;
  String? _pingMs;
  int _modelCount = 0;

  @override
  void initState() {
    super.initState();
    _agentName = widget.device.deviceName.isNotEmpty
        ? widget.device.deviceName
        : widget.device.agentId;
    _checkConnection();
  }

  Future<void> _checkConnection() async {
    setState(() => _checking = true);

    final rtc = WebRTCService(
      deviceId: widget.device.deviceId,
      agentId: widget.device.agentId,
      serverUrl: widget.settings.serverUrl,
    );

    final completer = Completer<void>();
    Timer? timeout;

    rtc.state.listen((state) {
      if (state == RTCState.connected) {
        _connected = true;
        // Fetch model list
        rtc.send(jsonEncode(WireMessage.create(MsgType.listModels, {}).toJson()));
        // Ping for latency
        final start = DateTime.now();
        rtc.send(jsonEncode(WireMessage.create(MsgType.ping, {}).toJson()));
        rtc.messages.listen((raw) {
          final wm = decodeWireMessage(raw);
          if (wm.type == MsgType.listResponse) {
            final models = (wm.body['models'] as List?) ?? [];
            _modelCount = models.length;
          }
          if (wm.type == MsgType.pong) {
            _pingMs = '${DateTime.now().difference(start).inMilliseconds}ms';
          }
        });
      }
    });

    timeout = Timer(const Duration(seconds: 8), () {
      _connected = false;
      if (!completer.isCompleted) completer.complete();
    });

    // Delay completion to allow responses to arrive
    rtc.state.listen((state) {
      if (state == RTCState.connected) {
        Future.delayed(const Duration(seconds: 2), () {
          if (!completer.isCompleted) completer.complete();
        });
      }
      if (state == RTCState.failed || state == RTCState.disconnected) {
        if (!completer.isCompleted) completer.complete();
      }
    });

    rtc.connect();
    await completer.future;
    timeout.cancel();
    rtc.dispose();

    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_agentName),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: '重命名',
            onPressed: _showRenameDialog,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Status card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                CircleAvatar(
                  radius: 32,
                  backgroundColor: Colors.grey.shade800,
                  child: Icon(Icons.computer, size: 36, color: Colors.grey.shade400),
                ),
                const SizedBox(height: 12),
                Text(_agentName, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                _checking
                    ? const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 8),
                        Text('检测中...'),
                      ])
                    : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(Icons.circle, size: 10, color: _connected ? Colors.green : Colors.grey),
                        const SizedBox(width: 6),
                        Text(_connected ? '在线' : '离线',
                            style: TextStyle(color: _connected ? Colors.green.shade400 : Colors.grey)),
                      ]),
              ]),
            ),
          ),

          // Info card
          Card(
            child: Column(children: [
              _InfoTile(icon: Icons.smart_toy, label: '搭载模型', value: '$_modelCount 个'),
              const Divider(height: 1, indent: 16, endIndent: 16),
              _InfoTile(icon: Icons.calendar_today, label: '配对时间', value: _fmt(widget.device.pairedAt)),
              const Divider(height: 1, indent: 16, endIndent: 16),
              _InfoTile(icon: Icons.fingerprint, label: '设备 ID', value: widget.device.deviceId),
            ]),
          ),

          // Actions
          const SizedBox(height: 8),
          Card(
            child: Column(children: [
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('测试连接'),
                subtitle: Text(_pingMs != null ? '延迟: $_pingMs' : '检测连通性'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  setState(() => _pingMs = null);
                  _checkConnection();
                },
              ),
            ]),
          ),

          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('解除配对'),
                  content: Text('确定解除与 $_agentName 的配对？\n相关对话记录将保留但无法继续对话。'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: FilledButton.styleFrom(backgroundColor: Colors.red),
                      child: const Text('解除'),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                await widget.store.removeDevice(widget.device.deviceId);
                if (mounted) Navigator.pop(context);
              }
            },
            style: OutlinedButton.styleFrom(foregroundColor: Colors.red.shade300),
            icon: const Icon(Icons.link_off),
            label: const Text('解除配对'),
          ),
        ],
      ),
    );
  }

  void _showRenameDialog() {
    final ctrl = TextEditingController(text: _agentName);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名 Agent'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入新名称'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final name = ctrl.text.trim();
              if (name.isNotEmpty) {
                setState(() => _agentName = name);
                // Save with updated deviceName
                final renamed = PairedDevice(
                  deviceId: widget.device.deviceId,
                  deviceName: name,
                  agentId: widget.device.agentId,
                  token: widget.device.token,
                  pairedAt: widget.device.pairedAt,
                );
                widget.store.addDevice(renamed);
                Navigator.pop(ctx);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  String _fmt(DateTime t) => '${t.year}/${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoTile({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, size: 20, color: Colors.grey),
      title: Text(label, style: Theme.of(context).textTheme.bodySmall),
      trailing: Text(value, style: Theme.of(context).textTheme.bodyMedium),
    );
  }
}
