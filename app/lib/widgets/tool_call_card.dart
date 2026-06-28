import 'dart:convert';
import 'package:flutter/material.dart';

import '../theme/crosslink_theme.dart';

/// 工具调用卡片 —— 深空链路风格
///
/// 左侧彩色强调条 + 工具 icon + 运行状态 + 可折叠 JSON 输入。
class ToolCallCard extends StatefulWidget {
  final String id;
  final String name;
  final Map<String, dynamic>? input;
  final String? resultSummary;
  final bool isError;
  final bool collapsed;

  const ToolCallCard({
    super.key,
    required this.id,
    required this.name,
    this.input,
    this.resultSummary,
    this.isError = false,
    this.collapsed = false,
  });

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late final AnimationController _iconCtrl;
  late final Animation<double> _iconTurns;

  @override
  void initState() {
    super.initState();
    _iconCtrl = AnimationController(
      vsync: this,
      duration: CrossLinkTheme.fast,
    );
    _iconTurns = Tween(begin: 0.0, end: 0.5).animate(_iconCtrl);
  }

  @override
  void didUpdateWidget(ToolCallCard old) {
    super.didUpdateWidget(old);
    if (widget.collapsed && !old.collapsed) {
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

  String _formattedInput() {
    if (widget.input == null || widget.input!.isEmpty) return '';
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(widget.input);
  }

  bool get _hasDetails =>
      (widget.input != null && widget.input!.isNotEmpty) ||
      (widget.resultSummary != null && widget.resultSummary!.isNotEmpty);

  bool get _isDone => widget.resultSummary != null || widget.isError;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final toolColor = widget.name.toolColor;
    final toolIcon = widget.name.toolIcon;

    return Padding(
      padding: const EdgeInsets.only(bottom: CrossLinkTheme.sMd),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(CrossLinkTheme.rMd),
        child: Container(
          decoration: BoxDecoration(
            color: CrossLinkTheme.surface.withAlpha(220),
            borderRadius: BorderRadius.circular(CrossLinkTheme.rMd),
            border: Border.all(
              color: widget.isError
                  ? CrossLinkTheme.error.withAlpha(120)
                  : cs.outlineVariant.withAlpha(50),
              width: 0.5,
            ),
            boxShadow: CrossLinkTheme.cardShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(width: 4, color: toolColor),
                    Expanded(
                      child: InkWell(
                        onTap: _hasDetails ? _toggle : null,
                        borderRadius: BorderRadius.circular(CrossLinkTheme.rMd),
                        child: Padding(
                          padding: const EdgeInsets.all(CrossLinkTheme.sMd),
                          child: Row(
                            children: [
                              Icon(toolIcon, size: 18, color: toolColor),
                              const SizedBox(width: CrossLinkTheme.sSm),
                              Expanded(
                                child: Text(
                                  widget.name,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: toolColor,
                                  ),
                                ),
                              ),
                              if (widget.id.isNotEmpty)
                                Text(
                                  widget.id.length > 8
                                      ? '#${widget.id.substring(0, 8)}'
                                      : '#${widget.id}',
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontFamily: 'monospace',
                                    color: cs.onSurface.withAlpha(80),
                                  ),
                                ),
                              const SizedBox(width: CrossLinkTheme.sSm),
                              _StatusDot(
                                isError: widget.isError,
                                isDone: _isDone,
                              ),
                              if (_hasDetails) ...[
                                const SizedBox(width: CrossLinkTheme.sXs),
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
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              AnimatedSize(
                duration: CrossLinkTheme.normal,
                curve: CrossLinkTheme.curve,
                alignment: Alignment.topCenter,
                child: _expanded && _hasDetails
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(
                          CrossLinkTheme.sMd,
                          0,
                          CrossLinkTheme.sMd,
                          CrossLinkTheme.sMd,
                        ),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 200),
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            if (widget.input != null && widget.input!.isNotEmpty)
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(CrossLinkTheme.sSm),
                                decoration: BoxDecoration(
                                  color: CrossLinkTheme.bg.withAlpha(160),
                                  borderRadius: BorderRadius.circular(CrossLinkTheme.rSm),
                                  border: Border.all(
                                    color: cs.outlineVariant.withAlpha(40),
                                    width: 0.5,
                                  ),
                                ),
                                child: SelectableText(
                                  _formattedInput(),
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    color: cs.onSurface.withAlpha(180),
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            if (widget.resultSummary != null &&
                                widget.resultSummary!.isNotEmpty) ...[
                              const SizedBox(height: CrossLinkTheme.sSm),
                              Text(
                                widget.resultSummary!,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSurface.withAlpha(140),
                                ),
                              ),
                            ],
                          ],
                            ),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final bool isError;
  final bool isDone;
  const _StatusDot({required this.isError, required this.isDone});

  @override
  Widget build(BuildContext context) {
    final color = isError
        ? CrossLinkTheme.error
        : isDone
            ? CrossLinkTheme.success
            : CrossLinkTheme.warning;

    return SizedBox(
      width: 14,
      height: 14,
      child: Center(
        child: isDone
            ? Icon(
                isError ? Icons.error_outline : Icons.check_circle_outline,
                size: 14,
                color: color,
              )
            : _PulseDot(color: color),
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _scale = Tween(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
    _opacity = Tween(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
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
      builder: (_, __) => Opacity(
        opacity: _opacity.value,
        child: Transform.scale(
          scale: _scale.value,
          child: Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: widget.color.withAlpha(120),
                  blurRadius: 6,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
