import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/pairing.dart';
import '../models/protocol.dart';
import '../services/device_store.dart';
import '../services/settings_service.dart';
import '../services/webrtc_service.dart';
import 'agent_detail_screen.dart';
import 'chat_screen.dart';

class AbilitiesScreen extends StatefulWidget {
  const AbilitiesScreen({super.key});

  @override
  State<AbilitiesScreen> createState() => AbilitiesScreenState();
}

class AbilitiesScreenState extends State<AbilitiesScreen>
    with SingleTickerProviderStateMixin {
  void refresh() {
    if (mounted) _load();
  }

  late TabController _tabCtrl;
  DeviceStore? _store;
  SettingsService? _settings;
  List<PairedDevice> _devices = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _tabCtrl.addListener(() {
      if (!_tabCtrl.indexIsChanging) {
        HapticFeedback.selectionClick();
      }
    });
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      DeviceStore.open(),
      SettingsService.open(),
    ]);
    if (mounted) {
      setState(() {
        _store = results[0] as DeviceStore;
        _settings = results[1] as SettingsService;
        _devices = _store!.loadDevices();
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 0,
        backgroundColor: Colors.transparent,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: TabBar(
              controller: _tabCtrl,
              labelStyle: Theme.of(context).textTheme.bodyMedium,
              tabs: const [
                Tab(text: '模型', icon: Icon(Icons.smart_toy, size: 18)),
                Tab(text: 'Agent', icon: Icon(Icons.dns, size: 18)),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    controller: _tabCtrl,
                    children: [
                      _ModelsTab(devices: _devices, settings: _settings!),
                      _AgentsTab(
                          devices: _devices,
                          store: _store!,
                          settings: _settings!,
                          onChanged: () => setState(() {})),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

// ---- Models Tab ----

class _ModelsTab extends StatefulWidget {
  final List<PairedDevice> devices;
  final SettingsService settings;
  const _ModelsTab({required this.devices, required this.settings});

  @override
  State<_ModelsTab> createState() => _ModelsTabState();
}

class _ModelsTabState extends State<_ModelsTab> {
  final Map<String, List<ModelInfo>> _agentModels = {};
  final Map<String, bool> _agentConnected = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetchAll();
  }

  Future<void> _fetchAll() async {
    setState(() => _loading = true);
    for (final device in widget.devices) {
      await _fetchModels(device);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _fetchModels(PairedDevice device) async {
    final rtc = WebRTCService(
      deviceId: device.deviceId,
      agentId: device.agentId,
      serverUrl: widget.settings.serverUrl,
    );
    final completer = Completer<void>();
    Timer? timeout;

    rtc.state.listen((state) {
      if (state == RTCState.connected) {
        rtc.send(
            jsonEncode(WireMessage.create(MsgType.listModels, {}).toJson()));
        _agentConnected[device.deviceId] = true;
      }
    });
    rtc.messages.listen((raw) {
      final wm = decodeWireMessage(raw);
      if (wm.type == MsgType.listResponse) {
        final models = (wm.body['models'] as List?)
                ?.map((m) => ModelInfo.fromJson(m as Map<String, dynamic>))
                .toList() ??
            [];
        // Also merge agent-grouped models if present
        final agents = (wm.body['agents'] as List?)
                ?.map((a) => AgentInfo.fromJson(a as Map<String, dynamic>))
                .toList();
        if (agents != null && agents.isNotEmpty) {
          for (final ag in agents) {
            _agentModels[device.deviceId + ':' + ag.type] = ag.models;
          }
        }
        _agentModels[device.deviceId] = models;
        if (!completer.isCompleted) completer.complete();
      }
    });
    timeout = Timer(const Duration(seconds: 8), () {
      _agentConnected[device.deviceId] = false;
      if (!completer.isCompleted) completer.complete();
    });
    rtc.connect();
    await completer.future;
    timeout.cancel();
    rtc.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final allEntries = <_ModelEntry>[];
    for (final device in widget.devices) {
      final models = _agentModels[device.deviceId] ?? [];
      for (final m in models) {
        allEntries.add(_ModelEntry(model: m, device: device));
      }
    }

    if (allEntries.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.smart_toy_outlined,
                size: 56, color: Colors.grey.shade700),
            const SizedBox(height: 12),
            Text('还没有发现模型',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('去信使页连接 Agent 后即可查看模型',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            FilledButton.tonal(
                onPressed: _fetchAll, child: const Text('刷新')),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchAll,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.all(8),
        itemCount: allEntries.length,
        itemBuilder: (_, i) {
          final entry = allEntries[i];
          final isDefault = widget.settings.model == entry.model.name;
          final cs = Theme.of(context).colorScheme;
          return Card(
            elevation: 0,
            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                    color: cs.outlineVariant.withAlpha(50), width: 0.5)),
            child: ListTile(
              leading: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDefault
                      ? Colors.amber.withAlpha(30)
                      : cs.primary.withAlpha(20),
                ),
                child: Icon(
                  isDefault ? Icons.star : Icons.smart_toy,
                  color: isDefault ? Colors.amber : cs.primary,
                  size: 20,
                ),
              ),
              title: Text(entry.model.name,
                  style: Theme.of(context).textTheme.bodyMedium),
              subtitle: Text(
                '${entry.device.deviceName.isNotEmpty ? entry.device.deviceName : entry.device.agentId}${_subtitle(entry.model)}',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Colors.grey.shade600),
              ),
              onTap: () {
                HapticFeedback.selectionClick();
                _showModelDetail(entry);
              },
            ),
          );
        },
      ),
    );
  }

  String _subtitle(ModelInfo m) {
    final parts = <String>[];
    if (m.paramSize.isNotEmpty) parts.add(m.paramSize);
    if (m.quant.isNotEmpty) parts.add(m.quant);
    if (parts.isEmpty) return '';
    return ' · ${parts.join(' · ')}';
  }

  void _showModelDetail(_ModelEntry entry) {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withAlpha(20),
                ),
                child: Icon(Icons.smart_toy,
                    color: Theme.of(context).colorScheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.model.name,
                          style:
                              Theme.of(context).textTheme.titleMedium),
                      Text(
                          '来自: ${entry.device.deviceName.isNotEmpty ? entry.device.deviceName : entry.device.agentId}',
                          style: Theme.of(context).textTheme.bodySmall),
                    ]),
              ),
            ]),
            const SizedBox(height: 16),
            if (entry.model.paramSize.isNotEmpty)
              _infoRow('参数规模', entry.model.paramSize),
            if (entry.model.quant.isNotEmpty)
              _infoRow('量化方式', entry.model.quant),
            _infoRow('来源 Agent',
                entry.device.deviceName.isNotEmpty ? entry.device.deviceName : entry.device.agentId),
            const Divider(height: 24),
            Row(children: [
              Expanded(
                child: FilledButton(
                  onPressed: () {
                    widget.settings.model = entry.model.name;
                    HapticFeedback.mediumImpact();
                    Navigator.pop(ctx);
                    setState(() {});
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content:
                            Text('已设为默认模型: ${entry.model.name}'),
                        duration: const Duration(seconds: 2),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                  child: Text(widget.settings.model == entry.model.name
                      ? '已是默认模型'
                      : '设为默认模型'),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChatScreen(
                        device: entry.device,
                        settings: widget.settings,
                        sessionId: null,
                        preSelectedModel: entry.model.name,
                      ),
                    ),
                  ).then((_) => setState(() {}));
                },
                child: const Text('测试对话'),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        SizedBox(
            width: 72,
            child: Text(label,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Colors.grey.shade500))),
        Expanded(child: Text(value)),
      ]),
    );
  }
}

class _ModelEntry {
  final ModelInfo model;
  final PairedDevice device;
  _ModelEntry({required this.model, required this.device});
}

// ---- Agents Tab ----

class _AgentsTab extends StatefulWidget {
  final List<PairedDevice> devices;
  final DeviceStore store;
  final SettingsService settings;
  final VoidCallback onChanged;

  const _AgentsTab({
    required this.devices,
    required this.store,
    required this.settings,
    required this.onChanged,
  });

  @override
  State<_AgentsTab> createState() => _AgentsTabState();
}

class _AgentsTabState extends State<_AgentsTab> {
  @override
  Widget build(BuildContext context) {
    if (widget.devices.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.dns_outlined, size: 56, color: Colors.grey.shade700),
            const SizedBox(height: 12),
            Text('还没有配对的 Agent',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('去信使页扫码配对即可添加',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      );
    }

    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.all(8),
      itemCount: widget.devices.length,
      itemBuilder: (_, i) {
        final device = widget.devices[i];
        final cs = Theme.of(context).colorScheme;
        return Card(
          elevation: 0,
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                  color: cs.outlineVariant.withAlpha(50), width: 0.5)),
          child: ListTile(
            leading: CircleAvatar(
              radius: 20,
              backgroundColor: cs.primary.withAlpha(20),
              child: Icon(Icons.computer, color: cs.primary, size: 22),
            ),
            title: Text(
                device.deviceName.isNotEmpty
                    ? device.deviceName
                    : device.agentId,
                style: Theme.of(context).textTheme.bodyMedium),
            subtitle: Text('配对于 ${_fmt(device.pairedAt)}',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Colors.grey.shade600)),
            trailing: PopupMenuButton<String>(
              icon:
                  const Icon(Icons.more_vert, size: 18),
              onSelected: (action) async {
                if (action == 'delete') {
                  HapticFeedback.heavyImpact();
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('解除配对'),
                      content: Text(
                          '确定解除与 ${device.deviceName.isNotEmpty ? device.deviceName : device.agentId} 的配对？'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('取消')),
                        FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('解除')),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    await widget.store.removeDevice(device.deviceId);
                    widget.onChanged();
                  }
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                    value: 'delete',
                    child: Text('解除配对',
                        style: TextStyle(color: Colors.red))),
              ],
            ),
            onTap: () {
              HapticFeedback.selectionClick();
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AgentDetailScreen(
                    device: device,
                    store: widget.store,
                    settings: widget.settings,
                  ),
                ),
              ).then((_) => widget.onChanged());
            },
          ),
        );
      },
    );
  }

  String _fmt(DateTime t) =>
      '${t.year}/${t.month.toString().padLeft(2, '0')}/${t.day.toString().padLeft(2, '0')}';
}
