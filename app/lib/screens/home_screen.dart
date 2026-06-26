import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../models/pairing.dart';
import '../services/http_service.dart';
import '../services/chat_history_service.dart';
import '../services/device_store.dart';
import '../services/settings_service.dart';
import '../theme/crosslink_theme.dart';
import '../widgets/animated_messenger.dart';
import '../widgets/shimmer_loading.dart';
import 'agent_select_screen.dart';
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

  Future<void> _manualPair() async {
    final tokenCtrl = TextEditingController();
    final urlCtrl = TextEditingController(text: 'http://crosslink.cyou:18080');
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: CrossLinkTheme.deepSpaceElevated,
        title: const Text('手动配对'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: urlCtrl,
            decoration: const InputDecoration(labelText: '服务器地址', hintText: 'http://crosslink.cyou:18080'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: tokenCtrl,
            decoration: const InputDecoration(labelText: '配对 Token', hintText: '从 Agent 控制台复制'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, {'url': urlCtrl.text.trim(), 'token': tokenCtrl.text.trim()}), child: const Text('配对')),
        ],
      ),
    );
    if (result == null || result['token']!.isEmpty) return;
    try {
      final device = await HttpPairing.pair(
        serverUrl: result['url']!,
        pairToken: result['token']!,
        deviceName: 'Web Browser',
      );
      if (mounted) _onDevicePaired(device);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('配对失败: $e')));
      }
    }
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
      backgroundColor: CrossLinkTheme.deepSpace,
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
      padding: const EdgeInsets.all(CrossLinkTheme.spaceLg),
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
        padding: const EdgeInsets.all(CrossLinkTheme.spaceXxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SvgPicture.asset(
              'assets/brand/empty_state_no_device.svg',
              width: 200,
              height: 170,
            ),
            const SizedBox(height: CrossLinkTheme.spaceXl),
            Text(
              '还没有配对的设备',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: CrossLinkTheme.spaceSm),
            Text(
              '扫描电脑端 CrossLink Agent 的二维码\n即可远程访问家中的 AI 模型',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: CrossLinkTheme.spaceXl),
            // Web 端手动配对（无摄像头）
            if (kIsWeb)
              FilledButton.icon(
                onPressed: () => _manualPair(),
                icon: const Icon(Icons.link),
                label: const Text('手动配对'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  backgroundColor: CrossLinkTheme.linkPurple,
                ),
              ),
            const SizedBox(height: 12),
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
              label: const Text(kIsWeb ? '扫码配对 (移动端)' : '扫码配对'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                backgroundColor: CrossLinkTheme.linkBlue,
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
            padding: const EdgeInsets.only(top: CrossLinkTheme.spaceLg, bottom: CrossLinkTheme.spaceXs),
            child: Column(
              children: [
                const AnimatedMessenger(
                  state: MessengerState.connected,
                  size: 72,
                ),
                const SizedBox(height: CrossLinkTheme.spaceSm),
                Text(
                  '${_devices.length} 个设备已配对',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: CrossLinkTheme.spaceMd),
          sliver: SliverList(
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
                          content: Text('删除后将清除 $count 个对话记录，确定继续？'),
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
                      margin: const EdgeInsets.symmetric(vertical: CrossLinkTheme.spaceXs),
                      decoration: BoxDecoration(
                        color: CrossLinkTheme.errorRed.withAlpha(160),
                        borderRadius: BorderRadius.circular(CrossLinkTheme.radiusMd),
                      ),
                      child: const Icon(Icons.delete, color: Colors.white),
                    ),
                    child: _DeviceCard(
                      device: device,
                      lastPreview: preview,
                      lastTime: time,
                      sessionCount: count,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        final latestId = sessions.isNotEmpty ? sessions.first : null;
                        Navigator.push(
                          context,
                          _slideRoute(AgentSelectScreen(
                            device: device,
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
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(CrossLinkTheme.spaceMd),
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
                side: const BorderSide(color: CrossLinkTheme.linkBlue),
                foregroundColor: CrossLinkTheme.linkCyan,
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
          ).animate(CurvedAnimation(parent: animation, curve: CrossLinkTheme.curveDefault)),
          child: FadeTransition(opacity: animation, child: child),
        );
      },
      transitionDuration: CrossLinkTheme.durationNormal,
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
      duration: CrossLinkTheme.durationSlow,
    );
    _slide = Tween(begin: 30.0, end: 0.0).animate(
      CurvedAnimation(parent: _ctrl, curve: CrossLinkTheme.curveDefault),
    );
    _fade = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
    Future.delayed(Duration(milliseconds: 60 * widget.index), () {
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
      margin: const EdgeInsets.symmetric(vertical: CrossLinkTheme.spaceXs),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CrossLinkTheme.radiusMd)),
      elevation: 0,
      color: CrossLinkTheme.panel.withAlpha(220),
      child: InkWell(
        borderRadius: BorderRadius.circular(CrossLinkTheme.radiusMd),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(CrossLinkTheme.radiusMd),
            border: Border.all(color: cs.outlineVariant.withAlpha(40), width: 0.5),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0x18FFFFFF), Colors.transparent],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(CrossLinkTheme.spaceMd),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const RadialGradient(colors: [
                      CrossLinkTheme.linkBlue,
                      CrossLinkTheme.linkPurple,
                    ]),
                    boxShadow: [
                      BoxShadow(
                        color: CrossLinkTheme.linkBlue.withAlpha(60),
                        blurRadius: 12,
                      ),
                    ],
                  ),
                  child: const Icon(Icons.computer, color: Colors.white, size: 22),
                ),
                const SizedBox(width: CrossLinkTheme.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: CrossLinkTheme.successGreen,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              device.deviceName.isNotEmpty ? device.deviceName : device.agentId,
                              style: Theme.of(context).textTheme.titleSmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      if (lastPreview != null)
                        Text(
                          lastPreview!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      if (lastPreview == null)
                        Text(
                          '点击开始对话',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontStyle: FontStyle.italic,
                              ),
                        ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (lastTime != null)
                      Text(lastTime!, style: Theme.of(context).textTheme.labelSmall),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: CrossLinkTheme.linkBlue.withAlpha(30),
                        borderRadius: BorderRadius.circular(CrossLinkTheme.radiusXl),
                      ),
                      child: Text(
                        '$sessionCount 会话',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: CrossLinkTheme.linkCyan, fontSize: 10),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, color: Colors.white54, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
