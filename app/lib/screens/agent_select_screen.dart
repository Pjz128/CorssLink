import 'package:flutter/material.dart';
import '../models/pairing.dart';
import '../models/protocol.dart';
import '../services/http_service.dart';
import '../services/settings_service.dart';
import '../theme/crosslink_theme.dart';
import 'chat_screen.dart';
import 'claude_session_list_screen.dart';

/// Agent 选择页面 — 在进入会话前选择 AI 后端。
class AgentSelectScreen extends StatefulWidget {
  final PairedDevice device;

  const AgentSelectScreen({super.key, required this.device});

  @override
  State<AgentSelectScreen> createState() => _AgentSelectScreenState();
}

class _AgentSelectScreenState extends State<AgentSelectScreen> {
  List<AgentInfo> _agents = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchAgents();
  }

  Future<void> _fetchAgents() async {
    final settings = _settingsFor(widget.device);
    final http = HttpService(baseUrl: settings['url']!, sessionToken: settings['token']!);
    try {
      final agents = await http.fetchAgents();
      if (mounted) setState(() { _agents = agents; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Map<String, String> _settingsFor(PairedDevice d) {
    if (d.serverUrl.isNotEmpty) return {'url': d.serverUrl, 'token': d.sessionToken};
    return {'url': 'http://crosslink.cyou:18080', 'token': d.sessionToken};
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CrossLinkTheme.deepSpace,
      appBar: AppBar(
        backgroundColor: CrossLinkTheme.deepSpace.withAlpha(220),
        title: Text(widget.device.deviceName.isNotEmpty ? widget.device.deviceName : widget.device.agentId),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('加载失败', style: TextStyle(color: Colors.white.withAlpha(150))),
                  const SizedBox(height: 12),
                  ElevatedButton(onPressed: () { setState(() { _loading = true; _error = null; }); _fetchAgents(); }, child: const Text('重试')),
                ]))
              : ListView.builder(
                  padding: const EdgeInsets.all(20),
                  itemCount: _agents.length,
                  itemBuilder: (ctx, i) {
                    final a = _agents[i];
                    final colors = _agentColor(a.type);
                    return Card(
                      color: CrossLinkTheme.panel,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      margin: const EdgeInsets.only(bottom: 12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () async {
                          final settings = await SettingsService.open();
                          if (!mounted) return;
                          final route = _routeFor(a, settings);
                          Navigator.pushReplacement(context, route);
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Row(children: [
                            Container(
                              width: 44, height: 44,
                              decoration: BoxDecoration(color: colors.$1.withAlpha(30), borderRadius: BorderRadius.circular(12)),
                              child: Icon(_iconFor(a.type), color: colors.$1, size: 22),
                            ),
                            const SizedBox(width: 14),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(a.label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                              const SizedBox(height: 4),
                              Text('${a.models.length} 个模型 · ${a.type}', style: TextStyle(fontSize: 12, color: colors.$1.withAlpha(180))),
                            ])),
                            Icon(Icons.arrow_forward_ios, size: 16, color: Colors.white.withAlpha(80)),
                          ]),
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  (Color, Color) _agentColor(String type) {
    switch (type) {
      case 'claude': return (CrossLinkTheme.linkCyan, Colors.cyanAccent);
      case 'deepseek': return (Colors.blue, Colors.blueAccent);
      case 'ollama': return (Colors.green, Colors.greenAccent);
      default: return (Colors.grey, Colors.grey);
    }
  }

  IconData _iconFor(String type) {
    switch (type) {
      case 'claude': return Icons.psychology;
      case 'deepseek': return Icons.cloud;
      case 'ollama': return Icons.memory;
      default: return Icons.smart_toy;
    }
  }

  /// Route to the appropriate screen for the given agent.
  Route _routeFor(AgentInfo a, SettingsService settings) {
    final model = a.models.isNotEmpty ? a.models.first.name : '';
    if (a.type == 'claude') {
      return MaterialPageRoute(builder: (_) => ClaudeSessionListScreen(
        device: widget.device,
        initialModel: model,
      ));
    }
    return MaterialPageRoute(builder: (_) => ChatScreen(
      device: widget.device,
      settings: settings,
      preSelectedModel: model,
    ));
  }
}
