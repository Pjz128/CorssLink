import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/protocol.dart';
import '../theme/crosslink_theme.dart';

/// 权限请求卡片 —— 深空链路风格
///
/// 与 ToolCallCard / ToolResultCard 共享时间线设计语言：
/// 左侧彩色强调条、顶部状态区、可折叠详情。
class PermissionCard extends StatefulWidget {
  final ChoiceRequestEvent event;
  final Future<bool> Function(String requestId, String behavior) onChoice;

  const PermissionCard({
    super.key,
    required this.event,
    required this.onChoice,
  });

  @override
  State<PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<PermissionCard>
    with SingleTickerProviderStateMixin {
  bool _responded = false;
  bool _sending = false;
  bool _expanded = true;

  late final AnimationController _iconCtrl;
  late final Animation<double> _iconTurns;

  @override
  void initState() {
    super.initState();
    _iconCtrl = AnimationController(
      vsync: this,
      duration: CrossLinkTheme.durationFast,
    );
    _iconTurns = Tween(begin: 0.0, end: 0.5).animate(_iconCtrl);
    _iconCtrl.forward();
  }

  @override
  void dispose() {
    _iconCtrl.dispose();
    super.dispose();
  }

  void _handleChoice(String behavior) async {
    if (_responded) return;
    setState(() {
      _responded = true;
      _sending = true;
    });
    HapticFeedback.mediumImpact();
    await widget.onChoice(widget.event.requestId, behavior);
    if (mounted) setState(() => _sending = false);
  }

  void _toggle() {
    setState(() {
      _expanded = !_expanded;
      if (_expanded) {
        _iconCtrl.forward();
      } else {
        _iconCtrl.reverse();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final event = widget.event;
    final color = event.toolName.toolColor;
    final hasInput = event.input != null && event.input!.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: CrossLinkTheme.spaceMd),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(CrossLinkTheme.radiusMd),
        child: Container(
          decoration: BoxDecoration(
            color: CrossLinkTheme.panel.withAlpha(220),
            borderRadius: BorderRadius.circular(CrossLinkTheme.radiusMd),
            border: Border.all(color: color.withAlpha(80), width: 1),
            boxShadow: CrossLinkTheme.panelShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 左侧强调条 + 头部
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(width: 4, color: color),
                    Expanded(
                      child: InkWell(
                        onTap: hasInput ? _toggle : null,
                        borderRadius: BorderRadius.circular(CrossLinkTheme.radiusMd),
                        child: Padding(
                          padding: const EdgeInsets.all(CrossLinkTheme.spaceMd),
                          child: Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: color.withAlpha(25),
                                  borderRadius: BorderRadius.circular(CrossLinkTheme.radiusSm),
                                ),
                                child: Icon(Icons.shield_outlined, size: 20, color: color),
                              ),
                              const SizedBox(width: CrossLinkTheme.spaceSm),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${event.toolName} 权限请求',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 14,
                                        color: color,
                                      ),
                                    ),
                                    if (event.decisionReason != null &&
                                        event.decisionReason!.isNotEmpty)
                                      Text(
                                        event.decisionReason!,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: cs.onSurface.withAlpha(150),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              if (hasInput)
                                AnimatedBuilder(
                                  animation: _iconTurns,
                                  builder: (_, child) => Transform.rotate(
                                    angle: _iconTurns.value * 3.14159,
                                    child: child,
                                  ),
                                  child: Icon(
                                    Icons.chevron_right,
                                    size: 18,
                                    color: cs.onSurface.withAlpha(120),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // 输入详情
              AnimatedSize(
                duration: CrossLinkTheme.durationNormal,
                curve: CrossLinkTheme.curveDefault,
                alignment: Alignment.topCenter,
                child: _expanded && hasInput
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(
                          CrossLinkTheme.spaceMd,
                          0,
                          CrossLinkTheme.spaceMd,
                          CrossLinkTheme.spaceMd,
                        ),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(CrossLinkTheme.spaceSm),
                          decoration: BoxDecoration(
                            color: CrossLinkTheme.deepSpace.withAlpha(160),
                            borderRadius: BorderRadius.circular(CrossLinkTheme.radiusSm),
                            border: Border.all(
                              color: cs.outlineVariant.withAlpha(40),
                              width: 0.5,
                            ),
                          ),
                          child: SelectableText(
                            const JsonEncoder.withIndent('  ').convert(event.input),
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              color: cs.onSurface.withAlpha(200),
                              height: 1.4,
                            ),
                            maxLines: 8,
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),

              // 操作按钮
              if (!_responded)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    CrossLinkTheme.spaceMd,
                    0,
                    CrossLinkTheme.spaceMd,
                    CrossLinkTheme.spaceMd,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _ChoiceButton(
                          label: '允许此次',
                          icon: Icons.check,
                          color: CrossLinkTheme.successGreen,
                          onTap: () => _handleChoice('allow'),
                        ),
                      ),
                      const SizedBox(width: CrossLinkTheme.spaceSm),
                      Expanded(
                        child: _ChoiceButton(
                          label: '拒绝',
                          icon: Icons.close,
                          color: CrossLinkTheme.errorRed,
                          onTap: () => _handleChoice('deny'),
                        ),
                      ),
                    ],
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    CrossLinkTheme.spaceMd,
                    0,
                    CrossLinkTheme.spaceMd,
                    CrossLinkTheme.spaceMd,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_sending)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        Icon(
                          Icons.check_circle_outline,
                          size: 18,
                          color: cs.onSurface.withAlpha(150),
                        ),
                      const SizedBox(width: CrossLinkTheme.spaceSm),
                      Text(
                        _sending ? '发送中…' : '已回复',
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurface.withAlpha(150),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChoiceButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _ChoiceButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: color.withAlpha(25),
          foregroundColor: color,
          side: BorderSide(color: color.withAlpha(100)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CrossLinkTheme.radiusSm),
          ),
          padding: const EdgeInsets.symmetric(vertical: 8),
          elevation: 0,
        ),
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(
          label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
