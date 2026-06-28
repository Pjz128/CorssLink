import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/crosslink_theme.dart';
import '../services/http_service.dart';
import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  final SettingsService? settings;

  const SettingsScreen({super.key, this.settings});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SettingsService? _settings;
  bool _checking = false;
  bool? _serverReachable;

  static const _themeColors = <_ThemeOption>[
    _ThemeOption('链路蓝', const Color(0xFF4C82FB)),
    _ThemeOption('墨玉绿', const Color(0xFF34C759)),
    _ThemeOption('琥珀橙', const Color(0xFFFF9F0A)),
    _ThemeOption('深绯红', const Color(0xFFFF453A)),
    _ThemeOption('紫罗兰', const Color(0xFFAF52DE)),
    _ThemeOption('青金石', const Color(0xFF5AC8FA)),
  ];

  @override
  void initState() {
    super.initState();
    if (widget.settings != null) {
      _settings = widget.settings;
    } else {
      SettingsService.open().then((s) {
        if (mounted) setState(() => _settings = s);
      });
    }
    _checkConnection();
  }

  Future<void> _checkConnection() async {
    if (_settings == null) return;
    setState(() => _checking = true);
    final ok = await HttpService(
      baseUrl: _settings!.serverUrl,
      sessionToken: '',
    ).healthCheck();
    if (mounted) setState(() {
      _serverReachable = ok;
      _checking = false;
    });
  }

  /// 遮罩 Agent ID，只显示首尾
  String _maskId(String id) {
    if (id.length <= 8) return id;
    return '${id.substring(0, 4)}⋯${id.substring(id.length - 4)}';
  }

  /// 提取服务器域名
  String _serverHost(String url) {
    try {
      final u = Uri.parse(url);
      return u.host;
    } catch (_) {
      return url;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final connected = _serverReachable == true;

    return Scaffold(
      backgroundColor: CrossLinkTheme.bg,
      appBar: AppBar(
        toolbarHeight: 0,
        backgroundColor: Colors.transparent,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      body: _settings == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.all(CrossLinkTheme.sLg),
                children: [
                  // ── 连接状态卡片 ──
                  _statusCard(context, connected),
                  const SizedBox(height: CrossLinkTheme.sXl),

                  // ── 服务器 ──
                  _sectionHeader('连接'),
                  _optionCard(
                    icon: Icons.dns_outlined,
                    title: '中继服务器',
                    subtitle: _serverHost(_settings!.serverUrl),
                    onTap: () => _showEditDialog(
                      title: '中继服务器地址',
                      initial: _settings!.serverUrl,
                      hint: 'http://crosslink.cyou:18080',
                      onSaved: (v) {
                        setState(() => _settings!.serverUrl = v);
                        _serverReachable = null;
                        _checkConnection();
                      },
                    ),
                  ),
                  _optionCard(
                    icon: Icons.fingerprint,
                    title: 'Agent 标识',
                    subtitle: _maskId(_settings!.agentId),
                    onTap: () => _showEditDialog(
                      title: 'Agent ID',
                      initial: _settings!.agentId,
                      hint: 'agent-ollama-pc',
                      onSaved: (v) => setState(() => _settings!.agentId = v),
                    ),
                  ),
                  const SizedBox(height: CrossLinkTheme.sXl),

                  // ── 模型 ──
                  _sectionHeader('模型'),
                  _optionCard(
                    icon: Icons.smart_toy_outlined,
                    title: '默认模型',
                    subtitle: _settings!.model.isNotEmpty ? _settings!.model : '未设置',
                    onTap: () => _showEditDialog(
                      title: '默认模型名称',
                      initial: _settings!.model,
                      hint: 'deepseek-chat / sonnet',
                      onSaved: (v) => setState(() => _settings!.model = v),
                    ),
                  ),
                  const SizedBox(height: CrossLinkTheme.sXl),

                  // ── 主题色 ──
                  _sectionHeader('主题色'),
                  const SizedBox(height: CrossLinkTheme.sSm),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: _themeColors.map((opt) {
                      final selected = _settings!.themeColor.toARGB32() == opt.color.toARGB32();
                      return GestureDetector(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          setState(() => _settings!.themeColor = opt.color);
                        },
                        child: Tooltip(
                          message: opt.label,
                          child: AnimatedContainer(
                            duration: CrossLinkTheme.fast,
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: opt.color,
                              borderRadius: BorderRadius.circular(14),
                              border: selected
                                  ? Border.all(color: Colors.white, width: 2.5)
                                  : Border.all(color: cs.outlineVariant.withAlpha(80), width: 1),
                              boxShadow: selected
                                  ? [
                                      BoxShadow(
                                        color: opt.color.withAlpha(140),
                                        blurRadius: 12,
                                        spreadRadius: 2,
                                      ),
                                    ]
                                  : null,
                            ),
                            child: selected
                                ? const Icon(Icons.check, color: Colors.white, size: 20)
                                : null,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: CrossLinkTheme.sXl),

                  // ── 关于 ──
                  _sectionHeader('关于'),
                  _aboutCard(context),
                  const SizedBox(height: CrossLinkTheme.sXxl),
                ],
              ),
            ),
    );
  }

  Widget _statusCard(BuildContext context, bool connected) {
    return Card(
      elevation: 0,
      color: connected
          ? CrossLinkTheme.success.withAlpha(15)
          : CrossLinkTheme.surface.withAlpha(200),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CrossLinkTheme.rMd),
        side: BorderSide(
          color: connected
              ? CrossLinkTheme.success.withAlpha(60)
              : Colors.white12,
          width: 0.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(CrossLinkTheme.sMd),
        child: Row(
          children: [
            AnimatedContainer(
              duration: CrossLinkTheme.normal,
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: connected
                    ? CrossLinkTheme.success
                    : CrossLinkTheme.surfaceHover,
                shape: BoxShape.circle,
                boxShadow: connected
                    ? [
                        BoxShadow(
                          color: CrossLinkTheme.success.withAlpha(100),
                          blurRadius: 8,
                        ),
                      ]
                    : null,
              ),
            ),
            const SizedBox(width: CrossLinkTheme.sMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    connected ? '已连接' : _checking ? '检测中…' : '未连接',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      color: connected
                          ? CrossLinkTheme.success
                          : Colors.white70,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    connected
                        ? '中继服务器运行正常'
                        : _serverReachable == null
                            ? '点击右侧按钮检测'
                            : '无法连接，请检查地址',
                    style: TextStyle(fontSize: 12, color: Colors.white38),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: _checking ? null : _checkConnection,
              icon: _checking
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded, size: 20),
              color: connected ? CrossLinkTheme.success : Colors.white38,
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: CrossLinkTheme.sSm),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: CrossLinkTheme.accent,
              fontSize: 13,
              letterSpacing: 0.5,
            ),
      ),
    );
  }

  Widget _optionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: CrossLinkTheme.sSm),
      color: CrossLinkTheme.surface.withAlpha(200),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CrossLinkTheme.rMd),
        side: BorderSide(color: cs.outlineVariant.withAlpha(50), width: 0.5),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: CrossLinkTheme.sMd,
          vertical: 2,
        ),
        leading: Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
            color: CrossLinkTheme.accent.withAlpha(15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: CrossLinkTheme.accent, size: 18),
        ),
        title: Text(title, style: Theme.of(context).textTheme.bodyMedium),
        subtitle: Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                fontSize: 11,
              ),
        ),
        trailing: const Icon(Icons.chevron_right, size: 18, color: Colors.white30),
        onTap: onTap,
      ),
    );
  }

  Widget _aboutCard(BuildContext context) {
    return Card(
      elevation: 0,
      color: CrossLinkTheme.surface.withAlpha(200),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CrossLinkTheme.rMd),
        side: BorderSide(color: Colors.white10, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(CrossLinkTheme.sMd),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(CrossLinkTheme.rSm),
                gradient: const LinearGradient(colors: [
                  CrossLinkTheme.accent,
                  CrossLinkTheme.accent,
                ]),
              ),
              child: SvgPicture.asset(
                'assets/brand/crosslink_logo.svg',
                width: 26,
                height: 26,
              ),
            ),
            const SizedBox(width: CrossLinkTheme.sMd),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('CrossLink',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  Text('跨端 AI 互联 · v1.3.0',
                      style: TextStyle(fontSize: 12, color: Colors.white38)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditDialog({
    required String title,
    required String initial,
    required String hint,
    required ValueChanged<String> onSaved,
  }) {
    final ctrl = TextEditingController(text: initial);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: CrossLinkTheme.surface,
        title: Text(title, style: const TextStyle(fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: Colors.white24, fontFamily: 'monospace', fontSize: 13),
            border: const OutlineInputBorder(),
            filled: true,
            fillColor: CrossLinkTheme.bg,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final v = ctrl.text.trim();
              if (v.isNotEmpty) {
                onSaved(v);
                HapticFeedback.lightImpact();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('已保存'),
                    duration: Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
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

class _ThemeOption {
  final String label;
  final Color color;
  const _ThemeOption(this.label, this.color);
}
