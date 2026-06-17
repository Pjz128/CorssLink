import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/pairing.dart';
import '../services/chat_history_service.dart';
import '../services/device_store.dart';
import '../services/settings_service.dart';
import 'chat_screen.dart';

class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key});

  @override
  State<SessionsScreen> createState() => SessionsScreenState();
}

class SessionsScreenState extends State<SessionsScreen> {
  void refresh() {
    if (mounted) _load();
  }

  DeviceStore? _store;
  SettingsService? _settings;
  ChatHistoryService? _history;
  List<PairedDevice> _devices = [];
  bool _loading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      DeviceStore.open(),
      SettingsService.open(),
      ChatHistoryService.open(),
    ]);
    if (mounted) {
      setState(() {
        _store = results[0] as DeviceStore;
        _settings = results[1] as SettingsService;
        _history = results[2] as ChatHistoryService;
        _devices = _store!.loadDevices();
        _loading = false;
      });
    }
  }

  List<Session> _filteredSessions(String deviceId) {
    final sessionIds = _history!.listSessions(deviceId);
    final sessions = sessionIds
        .map((sid) => _history!.load(sid))
        .whereType<Session>()
        .toList();
    if (_query.isEmpty) return sessions;
    final lower = _query.toLowerCase();
    return sessions
        .where((s) =>
            s.title.toLowerCase().contains(lower) ||
            s.messages.any((m) => m.content.toLowerCase().contains(lower)))
        .toList();
  }

  Future<void> _deleteSession(Session session) async {
    await _history!.delete(session.id);
    setState(() {});
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
      body: SafeArea(
        child: Column(
          children: [
            // Search bar
            if (!_loading && (_devices.isNotEmpty || _query.isNotEmpty))
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: TextField(
                  decoration: InputDecoration(
                    hintText: '搜索对话...',
                    prefixIcon:
                        const Icon(Icons.search, size: 20),
                    suffixIcon: _query.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () => setState(() => _query = ''),
                          )
                        : null,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    filled: true,
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            // Content
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _buildContent(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (_devices.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline,
                size: 56, color: Colors.grey.shade700),
            const SizedBox(height: 12),
            Text('还没有对话记录',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('去信使页连接 Agent 后开始对话吧',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      );
    }

    final allSessions = <_DeviceSection>[];
    for (final device in _devices) {
      final sessions = _filteredSessions(device.deviceId);
      if (sessions.isEmpty && _query.isNotEmpty) continue;
      allSessions.add(_DeviceSection(device: device, sessions: sessions));
    }

    if (allSessions.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 48, color: Colors.grey.shade600),
            const SizedBox(height: 12),
            Text('未找到匹配的对话',
                style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics()),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.only(bottom: 16),
        itemCount: allSessions.length,
        itemBuilder: (_, i) {
          final section = allSessions[i];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  section.device.deviceName.isNotEmpty
                      ? section.device.deviceName
                      : section.device.agentId,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Colors.grey.shade500, fontSize: 11),
                ),
              ),
              if (section.sessions.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 16, bottom: 8),
                  child: Text('暂无对话',
                      style: Theme.of(context).textTheme.bodySmall),
                )
              else
                ...section.sessions.map((s) => _SessionListTile(
                      session: s,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ChatScreen(
                              device: section.device,
                              settings: _settings!,
                              sessionId: s.id,
                            ),
                          ),
                        ).then((_) => setState(() {}));
                      },
                      onRename: () => _showRenameDialog(s),
                      onDelete: () => _deleteSession(s),
                    )),
            ],
          );
        },
      ),
    );
  }

  void _showRenameDialog(Session session) {
    final ctrl = TextEditingController(text: session.title);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名对话'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration:
              const InputDecoration(hintText: '输入新标题', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              final newTitle = ctrl.text.trim();
              if (newTitle.isNotEmpty) {
                session.title = newTitle;
                await _history!.save(session);
                HapticFeedback.lightImpact();
                if (mounted) setState(() {});
              }
              Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}

class _DeviceSection {
  final PairedDevice device;
  final List<Session> sessions;
  _DeviceSection({required this.device, required this.sessions});
}

class _SessionListTile extends StatelessWidget {
  final Session session;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _SessionListTile({
    required this.session,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = DateTime.fromMillisecondsSinceEpoch(session.updatedAt);
    final now = DateTime.now();
    final timeStr = now.difference(t).inDays > 0
        ? '${t.month}/${t.day}'
        : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
              color: cs.outlineVariant.withAlpha(50), width: 0.5)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500)),
                    const SizedBox(height: 2),
                    Text(
                      session.lastPreview.isNotEmpty
                          ? session.lastPreview
                          : '空对话',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(timeStr,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Colors.grey.shade600, fontSize: 11)),
                  const SizedBox(height: 2),
                  Text('${session.messages.length} 条消息',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Colors.grey.shade700, fontSize: 10)),
                ],
              ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert,
                    size: 16, color: Colors.grey.shade600),
                padding: EdgeInsets.zero,
                onSelected: (action) {
                  if (action == 'rename') onRename();
                  if (action == 'delete') onDelete();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                      value: 'rename',
                      child: Row(children: [
                        Icon(Icons.edit, size: 16),
                        SizedBox(width: 8),
                        Text('重命名'),
                      ])),
                  const PopupMenuItem(
                      value: 'delete',
                      child: Row(children: [
                        Icon(Icons.delete_outline, size: 16,
                            color: Colors.red),
                        SizedBox(width: 8),
                        Text('删除', style: TextStyle(color: Colors.red)),
                      ])),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
