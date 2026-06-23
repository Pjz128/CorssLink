import 'package:flutter/material.dart';
import '../models/protocol.dart';
import '../services/http_service.dart';
import '../services/device_store.dart';
import '../services/settings_service.dart';
import '../theme/crosslink_theme.dart';
import 'model_detail_screen.dart';

class ModelsScreen extends StatefulWidget {
  const ModelsScreen({super.key});
  @override
  State<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends State<ModelsScreen> {
  List<AgentInfo> _agents = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchModels();
  }

  Future<void> _fetchModels() async {
    setState(() { _loading = true; _error = null; });
    try {
      final settings = SettingsService.open();
      final baseUrl = settings.serverUrl;
      if (baseUrl.isEmpty) {
        setState(() { _error = '未配置服务器地址'; _loading = false; });
        return;
      }
      final devices = DeviceStore().loadDevices();
      if (devices.isEmpty) {
        setState(() { _error = '请先在家页配对 Agent'; _loading = false; });
        return;
      }
      final device = devices.first;
      final sessionToken = device.sessionToken;
      final http = HttpService(baseUrl: baseUrl, sessionToken: sessionToken);
      final agents = await http.fetchAgents();
      if (mounted) setState(() { _agents = agents; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48, color: CrossLinkTheme.textMuted),
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: CrossLinkTheme.textMuted)),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _fetchModels,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_agents.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.memory, size: 48, color: CrossLinkTheme.textMuted),
            const SizedBox(height: 12),
            Text('暂无可用模型', style: TextStyle(color: CrossLinkTheme.textMuted)),
            const SizedBox(height: 4),
            Text('配对 Agent 后自动获取', style: TextStyle(fontSize: 12, color: CrossLinkTheme.textMuted)),
          ],
        ),
      );
    }

    // Flatten: all models across all agents
    final entries = <_ModelEntry>[];
    for (final agent in _agents) {
      for (final model in agent.models) {
        entries.add(_ModelEntry(agent: agent, model: model));
      }
    }

    return RefreshIndicator(
      onRefresh: _fetchModels,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: entries.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final entry = entries[index];
          return _ModelCard(
            entry: entry,
            onTap: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => ModelDetailScreen(agentInfo: entry.agent, model: entry.model),
            )),
          );
        },
      ),
    );
  }
}

class _ModelEntry {
  final AgentInfo agent;
  final ModelInfo model;
  const _ModelEntry({required this.agent, required this.model});
}

class _ModelCard extends StatelessWidget {
  final _ModelEntry entry;
  final VoidCallback onTap;

  const _ModelCard({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final model = entry.model;
    final agent = entry.agent;
    return Card(
      color: CrossLinkTheme.deepSpaceCard,
      child: ListTile(
        leading: Icon(Icons.memory, color: CrossLinkTheme.accent),
        title: Text(model.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('${agent.label} · ${model.paramSize} · ${model.quant}'),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
