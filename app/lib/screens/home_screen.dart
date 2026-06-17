import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/pairing.dart';
import '../services/chat_history_service.dart';
import '../services/device_store.dart';
import '../services/settings_service.dart';
import '../widgets/animated_messenger.dart';
import '../widgets/shimmer_loading.dart';
import 'chat_screen.dart';
import 'scan_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  void refresh() {
    if (mounted) _load();
  }

  final List<PairedDevice> _devices = [];
  DeviceStore? _store;
  SettingsService? _settings;
  ChatHistoryService? _history;
  bool _loading = true;

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
        _devices.clear();
        _devices.addAll(_store!.loadDevices());
        _loading = false;
      });
    }
  }

  Future<void> _onDevicePaired(PairedDevice device) async {
    setState(() => _devices.add(device));
    await _store?.addDevice(device);
  }

  Future<void> _removeDevice(int index) async {
    final device = _devices.removeAt(index);
    for (final sid in _history!.listSessions(device.deviceId)) {
      await _history!.delete(sid);
    }
    await _store?.removeDevice(device.deviceId);
    setState(() {});
  }

  String? _lastPreview(String deviceId) {
    final sessions = _history!.listSessions(deviceId);
    if (sessions.isEmpty) return null;
    final s = _history!.load(sessions.first);
    return s?.lastPreview;
  }

  String? _lastTime(String deviceId) {
    final sessions = _history!.listSessions(deviceId);
    if (sessions.isEmpty) return null;
    final s = _history!.load(sessions.first);
    if (s == null) return null;
    final t = DateTime.fromMillisecondsSinceEpoch(s.updatedAt);
    final now = DateTime.now();
    if (now.difference(t).inDays > 0) return '${t.month}/${t.day}';
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  int _sessionCount(String deviceId) => _history!.listSessions(deviceId).length;

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
        child: _loading
            ? _buildLoading()
            : _devices.isEmpty
                ? _buildEmpty()
                : _buildContent(),
      ),
    );
  }

  Widget _buildLoading() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: const [
        SizedBox(height: 40),
        ShimmerCard(),
        ShimmerCard(),
        ShimmerCard(),
      ],
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const AnimatedMessenger(
              state: MessengerState.offline,
              size: 120,
            ),
            const SizedBox(height: 24),
            Text('还没有配对的设备',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '扫描电脑端 CrossLink Agent 的二维码\n即可远程访问家中的 AI 模型',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.grey.shade500),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: () async {
                HapticFeedback.mediumImpact();
                final result = await Navigator.push<PairedDevice>(
                  context,
                  _slideRoute(const ScanScreen()),
                );
                if (result != null) _onDevicePaired(result);
              },
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('扫码配对'),
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 4),
            child: Column(
              children: [
                const AnimatedMessenger(
                  state: MessengerState.connected,
                  size: 72,
                ),
                const SizedBox(height: 6),
                Text(
                  '${_devices.length} 个设备已配对',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.grey.shade500),
                ),
              ],
            ),
          ),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final device = _devices[index];
              final sessions = _history!.listSessions(device.deviceId);
              final preview = _lastPreview(device.deviceId);
              final time = _lastTime(device.deviceId);
              final count = _sessionCount(device.deviceId);

              return _StaggeredItem(
                index: index,
                child: Dismissible(
                  key: Key(device.deviceId),
                  direction: DismissDirection.endToStart,
                  confirmDismiss: (_) async {
                    HapticFeedback.heavyImpact();
                    return await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('删除设备'),
                        content:
                            Text('删除后将清除 $count 个对话记录，确定继续？'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('取消')),
                          FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('删除')),
                        ],
                      ),
                    );
                  },
                  onDismissed: (_) => _removeDevice(index),
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    margin:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                        color: Colors.red.shade800,
                        borderRadius: BorderRadius.circular(14)),
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  child: _DeviceCard(
                    device: device,
                    lastPreview: preview,
                    lastTime: time,
                    sessionCount: count,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      final latestId =
                          sessions.isNotEmpty ? sessions.first : null;
                      Navigator.push(
                        context,
                        _slideRoute(ChatScreen(
                          device: device,
                          settings: _settings!,
                          sessionId: latestId,
                        )),
                      ).then((_) => setState(() {}));
                    },
                  ),
                ),
              );
            },
            childCount: _devices.length,
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: OutlinedButton.icon(
              onPressed: () async {
                HapticFeedback.mediumImpact();
                final result = await Navigator.push<PairedDevice>(
                  context,
                  _slideRoute(const ScanScreen()),
                );
                if (result != null) _onDevicePaired(result);
              },
              icon: const Icon(Icons.add),
              label: const Text('添加设备'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Route<T> _slideRoute<T>(Widget page) {
    return PageRouteBuilder<T>(
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, animation, __, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.3, 0),
            end: Offset.zero,
          ).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: FadeTransition(opacity: animation, child: child),
        );
      },
      transitionDuration: const Duration(milliseconds: 280),
    );
  }
}

class _StaggeredItem extends StatefulWidget {
  final int index;
  final Widget child;
  const _StaggeredItem({required this.index, required this.child});

  @override
  State<_StaggeredItem> createState() => _StaggeredItemState();
}

class _StaggeredItemState extends State<_StaggeredItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _slide;
  late Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _slide = Tween(begin: 40.0, end: 0.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic),
    );
    _fade = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
    Future.delayed(Duration(milliseconds: 80 * widget.index), () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _slide.value),
          child: Opacity(opacity: _fade.value, child: child),
        );
      },
      child: widget.child,
    );
  }
}

class _DeviceCard extends StatelessWidget {
  final PairedDevice device;
  final String? lastPreview;
  final String? lastTime;
  final int sessionCount;
  final VoidCallback? onTap;

  const _DeviceCard({
    required this.device,
    this.lastPreview,
    this.lastTime,
    required this.sessionCount,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      elevation: 0,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: cs.outlineVariant.withAlpha(60), width: 0.5),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                cs.surfaceContainerHighest.withAlpha(40),
                cs.surfaceContainerHighest.withAlpha(10),
              ],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [
                      cs.primary.withAlpha(100),
                      cs.primary.withAlpha(20),
                    ]),
                    boxShadow: [
                      BoxShadow(
                          color: cs.primary.withAlpha(30), blurRadius: 8),
                    ],
                  ),
                  child: Icon(Icons.computer,
                      color: cs.primary.withAlpha(200), size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device.deviceName.isNotEmpty
                            ? device.deviceName
                            : device.agentId,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      if (lastPreview != null)
                        Text(lastPreview!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Colors.grey.shade500)),
                      if (lastPreview == null)
                        Text('点击开始对话',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Colors.grey.shade600,
                                fontStyle: FontStyle.italic)),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (lastTime != null)
                      Text(lastTime!,
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: Colors.grey.shade600)),
                    const SizedBox(height: 4),
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: cs.primary.withAlpha(25),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('$sessionCount 会话',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: cs.primary.withAlpha(180), fontSize: 10)),
                    ),
                  ],
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right,
                    color: Colors.grey.shade700, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
