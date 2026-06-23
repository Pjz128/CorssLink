import 'package:flutter/material.dart';
import '../models/protocol.dart';
import '../services/http_service.dart';
import '../services/settings_service.dart';
import '../services/device_store.dart';
import '../theme/crosslink_theme.dart';
import 'agent_detail_screen.dart';

class AgentsScreen extends StatefulWidget {
  const AgentsScreen({super.key});
  @override
  State<AgentsScreen> createState() => _AgentsScreenState();
}

class _AgentsScreenState extends State<AgentsScreen> {
  List<AgentInfo> _agents = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchAgents();
  }

  Future<void> _fetchAgents() async {
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
      final http = HttpService(baseUrl: baseUrl, sessionToken: device.sessionToken);
      final agents = await http.fetchAgents();
      if (mounted) setState(() { _agents = agents; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.cloud_off, size: 48, color: CrossLinkTheme.textMuted),
        const SizedBox(height: 12),
        Text(_error!, style: TextStyle(color: CrossLinkTheme.textMuted)),
        const SizedBox(height: 12),
        FilledButton.icon(onPressed: _fetchAgents, icon: const Icon(Icons.refresh), label: const Text('重试')),
      ]));
    }
    if (_agents.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.dns, size: 48, color: CrossLinkTheme.textMuted),
        const SizedBox(height: 12),
        Text('暂无已连接的 Agent', style: TextStyle(color: CrossLinkTheme.textMuted)),
      ]));
    }
    return RefreshIndicator(
      onRefresh: _fetchAgents,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: _agents.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final agent = _agents[index];
          return Card(
            color: CrossLinkTheme.deepSpaceCard,
            child: ListTile(
              leading: Icon(Icons.dns, color: CrossLinkTheme.accent),
              title: Text(agent.label, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('${agent.type} - ${agent.models.length} 个模型'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => AgentDetailScreen(deviceName: agent.label),
              )),
            ),
          );
        },
      ),
    );
  }
}
