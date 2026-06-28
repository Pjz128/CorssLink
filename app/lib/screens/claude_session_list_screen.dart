import 'package:flutter/material.dart';

import '../models/pairing.dart';
import '../services/http_service.dart';
import '../services/settings_service.dart';
import '../theme/crosslink_theme.dart';
import 'chat_screen.dart';

/// Claude 会话列表页 — 电脑端 /resume 的移动端视图。
///
/// 选择 Claude Agent 后进入此页面，展示电脑端所有 Claude 会话，
/// 选中某个会话后激活并加载历史上下文，进入聊天界面。
class ClaudeSessionListScreen extends StatefulWidget {
  final PairedDevice device;
  final String initialModel;

  const ClaudeSessionListScreen({
    super.key,
    required this.device,
    required this.initialModel,
  });

  @override
  State<ClaudeSessionListScreen> createState() => _ClaudeSessionListScreenState();
}

class _ClaudeSessionListScreenState extends State<ClaudeSessionListScreen> {
  HttpService? _http;
  List<Map<String, dynamic>> _sessions = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initHttp();
    _load();
  }

  void _initHttp() {
    final d = widget.device;
    final url = d.serverUrl.isNotEmpty ? d.serverUrl : 'http://crosslink.cyou:18080';
    _http = HttpService(baseUrl: url, sessionToken: d.sessionToken);
  }

  Future<void> _load() async {
    try {
      var sessions = await _http?.fetchClaudeSessions() ?? [];
      // 电脑端无会话时自动创建，给 Claude CLI 时间生成 .jsonl
      if (sessions.isEmpty) {
        await _http?.createClaudeSession('默认会话');
        await Future.delayed(const Duration(seconds: 2));
        sessions = await _http?.fetchClaudeSessions() ?? [];
      }
      if (mounted) setState(() { _sessions = sessions; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = '${e.toString()}\n\n请确认电脑端 Agent 已启动并连接中继'; _loading = false; });
    }
  }

  Future<void> _onSelect(Map<String, dynamic> session) async {
    final id = session['id'] as String? ?? '';
    final name = session['name'] as String? ?? '';
    if (id.isEmpty) return;

    // 激活选中的会话
    await _http?.activateClaudeSession(id);
    // 加载历史消息
    final messages = await _http?.fetchClaudeSessionMessages(id) ?? [];

    if (!mounted) return;

    final settings = await SettingsService.open();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          device: widget.device,
          settings: settings,
          preSelectedModel: widget.initialModel,
          claudeSessionName: name,
          preloadedMessages: messages,
        ),
      ),
    );
  }

  Future<void> _onCreate() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: CrossLinkTheme.surface,
        title: const Text('新建会话'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '会话名称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await _http?.createClaudeSession(name);
    // 新会话直接进入聊天，首次消息后 .jsonl 自动创建
    final settings = await SettingsService.open();
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ChatScreen(
      device: widget.device,
      settings: settings,
      preSelectedModel: widget.initialModel,
      claudeSessionName: name,
    )));
  }

  @override
  Widget build(BuildContext context) {
    final active = _sessions.where((s) => s['active'] == true).toList();
    final inactive = _sessions.where((s) => s['active'] != true).toList();

    return Scaffold(
      backgroundColor: CrossLinkTheme.bg,
      appBar: AppBar(
        backgroundColor: CrossLinkTheme.bg.withAlpha(220),
        title: const Text('Claude 会话'),
        actions: [
          IconButton(icon: const Icon(Icons.add, size: 22), onPressed: _onCreate),
        ],
      ),
      body: _loading
          ? const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                CircularProgressIndicator(color: CrossLinkTheme.accent),
                SizedBox(height: 16),
                Text('正在读取电脑端会话…', style: TextStyle(color: Colors.white38, fontSize: 13)),
                SizedBox(height: 4),
                Text('请确保 PC Agent 在线', style: TextStyle(color: Colors.white24, fontSize: 11)),
              ]))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.wifi_off, size: 40, color: Colors.white24),
                      const SizedBox(height: 16),
                      Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: Colors.white.withAlpha(150), fontSize: 13)),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: () { setState(() { _loading = true; _error = null; }); _load(); },
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('重试'),
                      ),
                    ]),
                  ))
              : _sessions.isEmpty
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.folder_open, size: 48, color: Colors.white24),
                        const SizedBox(height: 16),
                        const Text('暂无会话', style: TextStyle(color: Colors.white38, fontSize: 14)),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _onCreate,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('新建会话'),
                        ),
                      ]))
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        // 活跃会话
                        if (active.isNotEmpty) ...[
                          const Padding(
                            padding: EdgeInsets.only(left: 4, bottom: 8),
                            child: Text('当前活跃', style: TextStyle(fontSize: 11, color: Colors.white38, letterSpacing: 0.5)),
                          ),
                          ...active.map((s) => _buildItem(s, true)),
                        ],
                        // 非活跃会话
                        if (inactive.isNotEmpty) ...[
                          if (active.isNotEmpty)
                            const Padding(
                              padding: EdgeInsets.only(left: 4, top: 12, bottom: 8),
                              child: Text('可切换', style: TextStyle(fontSize: 11, color: Colors.white38, letterSpacing: 0.5)),
                            ),
                          ...inactive.map((s) => _buildItem(s, false)),
                        ],
                      ],
                    ),
    );
  }

  Widget _buildItem(Map<String, dynamic> s, bool isActive) {
    final name = s['name'] as String? ?? '';
    final model = s['model'] as String? ?? '';
    final id = s['id'] as String? ?? '';

    return Card(
      color: isActive
          ? CrossLinkTheme.success.withAlpha(12)
          : CrossLinkTheme.surface.withAlpha(200),
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CrossLinkTheme.rSm),
        side: BorderSide(
          color: isActive ? CrossLinkTheme.success.withAlpha(50) : Colors.white10,
          width: 0.5,
        ),
      ),
      child: ListTile(
        onTap: () => _onSelect(s),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: Icon(
          isActive ? Icons.folder_open : Icons.folder_outlined,
          size: 22,
          color: isActive ? CrossLinkTheme.success : Colors.white38,
        ),
        title: Text(name, style: TextStyle(fontSize: 14, fontWeight: isActive ? FontWeight.w600 : FontWeight.w400)),
        subtitle: Text(model, style: const TextStyle(fontSize: 11, color: Colors.white38)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isActive)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: CrossLinkTheme.success.withAlpha(25),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text('活跃', style: TextStyle(fontSize: 9, color: CrossLinkTheme.success)),
              ),
            if (!isActive)
              IconButton(
                icon: const Icon(Icons.close, size: 16, color: Colors.white24),
                onPressed: () async {
                  await _http?.deleteClaudeSession(id);
                  _load();
                },
              ),
          ],
        ),
      ),
    );
  }
}
