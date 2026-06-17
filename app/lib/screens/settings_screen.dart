import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  final SettingsService? settings;
  const SettingsScreen({super.key, this.settings});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SettingsService? _settings;

  static const _themeColors = <_ThemeOption>[
    _ThemeOption('深蓝', Color(0xFF1a1a2e)),
    _ThemeOption('墨绿', Color(0xFF1b4332)),
    _ThemeOption('暗紫', Color(0xFF3c096c)),
    _ThemeOption('深红', Color(0xFF660708)),
    _ThemeOption('灰蓝', Color(0xFF2b3a67)),
    _ThemeOption('深橙', Color(0xFF5c3d2e)),
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
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
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
                padding: const EdgeInsets.all(16),
                children: [
                  _sectionHeader('连接'),
                  _optionCard(
                    context: context,
                    icon: Icons.cloud_outlined,
                    title: '信令服务器',
                    subtitle: _settings!.serverUrl,
                    onTap: () => _showEditDialog(
                      title: '信令服务器地址',
                      initial: _settings!.serverUrl,
                      hint: 'ws://45.197.144.16:18080',
                      onSaved: (v) =>
                          setState(() => _settings!.serverUrl = v),
                    ),
                  ),
                  _optionCard(
                    context: context,
                    icon: Icons.tag,
                    title: 'Agent ID',
                    subtitle: _settings!.agentId,
                    onTap: () => _showEditDialog(
                      title: 'Agent ID',
                      initial: _settings!.agentId,
                      hint: 'agent-ollama-pc',
                      onSaved: (v) =>
                          setState(() => _settings!.agentId = v),
                    ),
                  ),
                  const SizedBox(height: 20),
                  _sectionHeader('模型'),
                  _optionCard(
                    context: context,
                    icon: Icons.smart_toy_outlined,
                    title: '默认模型',
                    subtitle: _settings!.model,
                    onTap: () => _showEditDialog(
                      title: '默认模型名称',
                      initial: _settings!.model,
                      hint: 'deepseek-chat',
                      onSaved: (v) =>
                          setState(() => _settings!.model = v),
                    ),
                  ),
                  const SizedBox(height: 20),
                  _sectionHeader('主题色'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 14,
                    runSpacing: 14,
                    children: _themeColors.map((opt) {
                      final selected = _settings!.themeColor.toARGB32() ==
                          opt.color.toARGB32();
                      return GestureDetector(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          setState(() => _settings!.themeColor = opt.color);
                        },
                        child: Tooltip(
                          message: opt.label,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: opt.color,
                              shape: BoxShape.circle,
                              border: selected
                                  ? Border.all(
                                      color: Colors.white, width: 3)
                                  : Border.all(
                                      color: Colors.grey.shade700,
                                      width: 1),
                              boxShadow: selected
                                  ? [
                                      BoxShadow(
                                          color: opt.color.withAlpha(100),
                                          blurRadius: 12,
                                          spreadRadius: 2)
                                    ]
                                  : null,
                            ),
                            child: selected
                                ? const Icon(Icons.check,
                                    color: Colors.white, size: 20)
                                : null,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 24),
                  _sectionHeader('关于'),
                  Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                            color: cs.outlineVariant.withAlpha(50),
                            width: 0.5)),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              gradient: LinearGradient(colors: [
                                cs.primary,
                                cs.primary.withAlpha(180),
                              ]),
                            ),
                            child: const Icon(Icons.link,
                                color: Colors.white, size: 22),
                          ),
                          const SizedBox(width: 14),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('CrossLink',
                                    style: TextStyle(
                                        fontWeight: FontWeight.w600)),
                                Text('跨端 AI 互联 · v1.0.0',
                                    style: TextStyle(fontSize: 12)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
    );
  }

  Widget _sectionHeader(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text,
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(fontWeight: FontWeight.w600)),
    );
  }

  Widget _optionCard({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: cs.outlineVariant.withAlpha(50), width: 0.5)),
      child: ListTile(
        leading:
            Icon(icon, color: cs.primary.withAlpha(180), size: 22),
        title: Text(title,
            style: Theme.of(context).textTheme.bodyMedium),
        subtitle: Text(subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.grey.shade500)),
        trailing:
            Icon(Icons.chevron_right, size: 18, color: Colors.grey.shade600),
        onTap: onTap,
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
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
              hintText: hint, border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
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
                      behavior: SnackBarBehavior.floating),
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
