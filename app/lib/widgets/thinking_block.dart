import 'package:flutter/material.dart';

import '../theme/crosslink_theme.dart';

/// 思考块 —— 深空链路风格
///
/// 折叠/展开 Claude 的内部推理，流式接收时自动展开。
/// 响应完成后自动折叠，内容区固定最大高度。
class ThinkingBlock extends StatefulWidget {
  final String content;
  final bool isStreaming;
  final bool collapsed;

  const ThinkingBlock({
    super.key,
    required this.content,
    this.isStreaming = false,
    this.collapsed = false,
  });

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock>
    with SingleTickerProviderStateMixin {
  bool _expanded;
  late final AnimationController _iconCtrl;
  late final Animation<double> _iconTurns;

  _ThinkingBlockState() : _expanded = true;

  @override
  void initState() {
    super.initState();
    _iconCtrl = AnimationController(
      vsync: this,
      duration: CrossLinkTheme.durationFast,
    );
    _iconTurns = Tween(begin: 0.0, end: 0.5).animate(_iconCtrl);
    _expanded = widget.isStreaming && !widget.collapsed;
    if (_expanded) _iconCtrl.forward();
  }

  @override
  void didUpdateWidget(ThinkingBlock old) {
    super.didUpdateWidget(old);
    // 外部强制折叠
    if (widget.collapsed && !old.collapsed) {
      setState(() {
        _expanded = false;
        _iconCtrl.reverse();
      });
      return;
    }
    // 开始流式 → 自动展开
    if (widget.isStreaming && !old.isStreaming) {
      setState(() {
        _expanded = true;
        _iconCtrl.forward();
      });
    }
    // 停止流式 → 自动折叠
    if (!widget.isStreaming && old.isStreaming) {
      setState(() {
        _expanded = false;
        _iconCtrl.reverse();
      });
    }
  }

  @override
  void dispose() {
    _iconCtrl.dispose();
    super.dispose();
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

  static const _maxContentHeight = 200.0;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: CrossLinkTheme.spaceMd),
      child: Container(
        decoration: BoxDecoration(
          color: CrossLinkTheme.panel.withAlpha(160),
          borderRadius: BorderRadius.circular(CrossLinkTheme.radiusMd),
          border: Border.all(
            color: cs.outlineVariant.withAlpha(60),
            width: 0.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(CrossLinkTheme.radiusMd),
              onTap: _toggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: CrossLinkTheme.spaceMd,
                  vertical: CrossLinkTheme.spaceSm,
                ),
                child: Row(
                  children: [
                    if (widget.isStreaming)
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: CrossLinkTheme.linkCyan.withAlpha(180),
                        ),
                      )
                    else
                      Icon(
                        Icons.psychology,
                        size: 14,
                        color: cs.onSurface.withAlpha(140),
                      ),
                    const SizedBox(width: CrossLinkTheme.spaceSm),
                    Text(
                      widget.isStreaming ? '思考中…' : '思考完成',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withAlpha(160),
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    const Spacer(),
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
            AnimatedSize(
              duration: CrossLinkTheme.durationNormal,
              curve: CrossLinkTheme.curveDefault,
              alignment: Alignment.topCenter,
              child: _expanded
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(
                        CrossLinkTheme.spaceMd,
                        0,
                        CrossLinkTheme.spaceMd,
                        CrossLinkTheme.spaceMd,
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: _maxContentHeight),
                        child: SingleChildScrollView(
                          child: Text(
                            widget.content,
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurface.withAlpha(160),
                              fontStyle: FontStyle.italic,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}
