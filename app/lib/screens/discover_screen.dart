import 'dart:async';

import 'package:flutter/material.dart';

import '../models/discover.dart';
import '../services/device_store.dart';
import '../services/http_service.dart';
import '../services/settings_service.dart';
import '../theme/crosslink_theme.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => DiscoverScreenState();
}

class DiscoverScreenState extends State<DiscoverScreen> {
  DeviceStore? _store;
  SettingsService? _settings;
  HttpService? _http;
  bool _loading = true;
  String _statusText = '加载中...';
  List<DiscoveredAgent> _agents = [];
  Timer? _requestPoller;

  // 建联申请状态追踪
  final Map<String, String> _requestStatus = {}; // peerID → status

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _requestPoller?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      DeviceStore.open(),
      SettingsService.open(),
    ]);
    if (!mounted) return;

    final store = results[0] as DeviceStore;
    final settings = results[1] as SettingsService;
    setState(() {
      _store = store;
      _settings = settings;
    });

    // 找一个可用的 session token
    _initHttpService(store, settings);
    if (_http != null) {
      await refresh();
    } else {
      setState(() {
        _loading = false;
        _statusText = '暂无可用的中继连接\n请先在「设备」页扫码配对';
      });
    }
  }

  void _initHttpService(DeviceStore store, SettingsService settings) {
    final devices = store.loadDevices();
    final relayUrl = settings.serverUrl;

    for (final d in devices) {
      // 优先使用匹配当前 relay 的设备
      if (d.serverUrl.isNotEmpty && d.sessionToken.isNotEmpty) {
        _http = HttpService(baseUrl: relayUrl, sessionToken: d.sessionToken);
        return;
      }
    }
    // 备选：第一个有 token 的设备
    for (final d in devices) {
      if (d.sessionToken.isNotEmpty) {
        _http = HttpService(baseUrl: relayUrl, sessionToken: d.sessionToken);
        return;
      }
    }
  }

  Future<void> refresh() async {
    if (_http == null) return;
    setState(() => _statusText = '加载中...');

    try {
      final agents = await _http!.fetchDiscoverAgents();
      // 刷新建联状态
      final requests = await _http!.fetchConnectionRequests();
      final statusMap = <String, String>{};
      for (final r in requests) {
        if (r.isApproved) {
          statusMap[r.peerID] = 'approved';
          // 自动完成配对
          _autoPair(r);
        } else if (r.isRejected) {
          statusMap[r.peerID] = 'rejected';
        } else {
          statusMap[r.peerID] = 'pending';
        }
      }

      if (!mounted) return;
      setState(() {
        _agents = agents;
        _requestStatus.clear();
        _requestStatus.addAll(statusMap);
        _statusText = agents.isEmpty ? '暂无可发现的 Agent' : '${agents.length} 个 Agent 在线';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = '加载失败: $e';
        _loading = false;
      });
    }
  }

  Future<void> _autoPair(ConnectionRequest req) async {
    if (req.pairToken == null || req.pairToken!.isEmpty) return;
    if (_store == null || _settings == null) return;

    try {
      final device = await HttpPairing.pair(
        serverUrl: _settings!.serverUrl,
        pairToken: req.pairToken!,
        deviceName: 'Agent (${req.peerID})',
      );
      await _store!.addDevice(device);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已成功连接到 ${req.peerID}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('自动配对失败: $e')),
        );
      }
    }
  }

  Future<void> _requestConnect(DiscoveredAgent agent) async {
    if (_http == null) return;

    // 确认弹窗
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('请求建联'),
        content: Text(
          '向 ${agent.ownerLabel}\n'
          '申请连接到 Agent「${agent.peerID}」？\n\n'
          '对方需在 Dashboard 审批后才可连接。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('发送申请'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final result = await _http!.requestConnect(agent.peerID);
    final status = result['status'] as String? ?? 'error';

    if (!mounted) return;

    if (status == 'approved') {
      // 直接获批（未认领 agent）
      final pairToken = result['pairToken'] as String?;
      if (pairToken != null && pairToken.isNotEmpty) {
        try {
          final device = await HttpPairing.pair(
            serverUrl: _settings!.serverUrl,
            pairToken: pairToken,
            deviceName: 'Agent (${agent.peerID})',
          );
          await _store?.addDevice(device);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已认领并连接 ${agent.peerID}')),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('配对失败: $e')),
            );
          }
        }
      }
      refresh();
    } else if (status == 'pending') {
      setState(() => _requestStatus[agent.peerID] = 'pending');
      // 启动轮询
      _startPolling();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('建联申请已发送，等待对方审批')),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result['message'] as String? ?? '请求失败')),
        );
      }
    }
  }

  void _startPolling() {
    _requestPoller?.cancel();
    _requestPoller = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_http != null && _requestStatus.containsValue('pending')) {
        refresh();
        if (!_requestStatus.containsValue('pending')) {
          _requestPoller?.cancel();
        }
      } else {
        _requestPoller?.cancel();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('发现'),
        centerTitle: true,
        actions: [
          if (_agents.isNotEmpty)
            Text('${_agents.length} 在线', style: const TextStyle(fontSize: 13)),
          const SizedBox(width: 12),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_http == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.wifi_off_rounded, size: 64,
                  color: CrossLinkTheme.panel),
              const SizedBox(height: 16),
              Text(
                _statusText,
                textAlign: TextAlign.center,
                style: TextStyle(color: CrossLinkTheme.panel, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }

    if (_agents.isEmpty) {
      return RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          children: [
            SizedBox(height: MediaQuery.of(context).size.height * 0.3),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.explore_outlined, size: 64,
                      color: CrossLinkTheme.panel),
                  const SizedBox(height: 16),
                  Text(
                    _statusText,
                    style: TextStyle(color: CrossLinkTheme.panel, fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '下拉刷新重试',
                    style: TextStyle(color: CrossLinkTheme.panel.withAlpha(150), fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: _agents.length,
        itemBuilder: (_, i) => _buildAgentCard(_agents[i]),
      ),
    );
  }

  Widget _buildAgentCard(DiscoveredAgent agent) {
    final reqStatus = _requestStatus[agent.peerID];

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: CrossLinkTheme.deepSpaceElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: agent.isOwn
            ? const BorderSide(color: Color(0xFF4CAF50), width: 0.5)
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 第一行：状态 + 可见性
            Row(
              children: [
                // 在线状态灯
                Container(
                  width: 8, height: 8,
                  decoration: const BoxDecoration(
                    color: Color(0xFF4CAF50),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                const Text('在线', style: TextStyle(fontSize: 12, color: Color(0xFF4CAF50))),
                const Spacer(),
                // 可见性徽章
                _visibilityBadge(agent),
              ],
            ),
            const SizedBox(height: 8),

            // peerID
            Text(
              agent.peerID,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),

            // 归属 + 在线时长
            Row(
              children: [
                _ownerBadge(agent),
                const SizedBox(width: 12),
                Text(
                  agent.onlineDuration,
                  style: TextStyle(fontSize: 12, color: CrossLinkTheme.panel),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // 能力 Chips
            if (agent.metadata != null && agent.metadata!.capabilities.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: agent.metadata!.capabilities
                    .map((c) => _capabilityChip(c))
                    .toList(),
              ),
            const SizedBox(height: 10),

            // 操作按钮
            _buildActionButton(agent, reqStatus),
          ],
        ),
      ),
    );
  }

  Widget _visibilityBadge(DiscoveredAgent agent) {
    final isPublic = agent.visibility == 'public';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isPublic
            ? const Color(0xFF4CAF50).withAlpha(30)
            : const Color(0xFF9E9E9E).withAlpha(30),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isPublic ? Icons.lock_open_rounded : Icons.lock_rounded,
            size: 11,
            color: isPublic ? const Color(0xFF4CAF50) : const Color(0xFF9E9E9E),
          ),
          const SizedBox(width: 4),
          Text(
            isPublic ? '公开' : '私有',
            style: TextStyle(
              fontSize: 11,
              color: isPublic ? const Color(0xFF4CAF50) : const Color(0xFF9E9E9E),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ownerBadge(DiscoveredAgent agent) {
    Color badgeColor;
    IconData icon;

    if (!agent.claimed) {
      badgeColor = const Color(0xFF9E9E9E);
      icon = Icons.block_outlined;
    } else if (agent.isOwn) {
      badgeColor = const Color(0xFF4CAF50);
      icon = Icons.check_circle_outline;
    } else {
      badgeColor = const Color(0xFF2196F3);
      icon = Icons.person_outline;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: badgeColor.withAlpha(25),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: badgeColor),
          const SizedBox(width: 4),
          Text(agent.ownerLabel,
              style: TextStyle(fontSize: 11, color: badgeColor)),
        ],
      ),
    );
  }

  Widget _capabilityChip(String cap) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: CrossLinkTheme.linkBlue.withAlpha(25),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        cap,
        style: TextStyle(
          fontSize: 11,
          color: CrossLinkTheme.linkBlue,
          fontFamily: 'monospace',
        ),
      ),
    );
  }

  Widget _buildActionButton(DiscoveredAgent agent, String? reqStatus) {
    // 已批准的申请
    if (reqStatus == 'approved') {
      return const SizedBox(
        width: double.infinity,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle, size: 20, color: Color(0xFF4CAF50)),
            SizedBox(width: 8),
            Text('已连接', style: TextStyle(color: Color(0xFF4CAF50))),
          ],
        ),
      );
    }

    // 等待审批
    if (reqStatus == 'pending') {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: null,
          icon: const SizedBox(
            width: 14, height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          label: const Text('等待审批...'),
        ),
      );
    }

    // 已拒绝
    if (reqStatus == 'rejected') {
      return SizedBox(
        width: double.infinity,
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: null,
                icon: const Icon(Icons.close, size: 16, color: Colors.red),
                label: const Text('已拒绝', style: TextStyle(color: Colors.red)),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => _requestConnect(agent),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    // 自己的 agent → 已连接（不可操作）
    if (agent.isOwn) {
      return const SizedBox(
        width: double.infinity,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline, size: 20, color: Color(0xFF4CAF50)),
            SizedBox(width: 8),
            Text('已连接', style: TextStyle(color: Color(0xFF4CAF50))),
          ],
        ),
      );
    }

    // 未认领 → 认领并连接
    if (!agent.claimed) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: () => _requestConnect(agent),
          icon: const Icon(Icons.add_link, size: 18),
          label: const Text('认领并连接'),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF4CAF50),
          ),
        ),
      );
    }

    // 他人的公开 agent → 请求建联
    if (agent.canRequest) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: () => _requestConnect(agent),
          icon: const Icon(Icons.send_rounded, size: 18),
          label: const Text('请求建联'),
        ),
      );
    }

    return const SizedBox.shrink();
  }
}
