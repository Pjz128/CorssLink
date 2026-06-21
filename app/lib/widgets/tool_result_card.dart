import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/crosslink_theme.dart';

/// 工具结果卡片 —— 深空链路风格
///
/// 与 ToolCallCard / PermissionCard 共享设计语言，强调等宽字体与复制能力。
class ToolResultCard extends StatefulWidget {
  final String output;
  final bool isError;
  final String? toolId;
  final String? toolName;
  final bool collapsed;

  const ToolResultCard({
    super.key,
    required this.output,
    this.isError = false,
    this.toolId,
    this.toolName,
    this.collapsed = false,
  });

  @override
  State<ToolResultCard> createState() => _ToolResultCardState();
}

class _ToolResultCardState extends State<ToolResultCard>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late final AnimationController _iconCtrl;
  late final Animation<double> _iconTurns;

  String get _sizeLabel {
    final bytes = widget.output.length;
    if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  @override
  void initState() {
    super.initState();
    _iconCtrl = AnimationController(
      vsync: this,
      duration: CrossLinkTheme.durationFast,
    );
    _iconTurns = Tween(begin: 0.0, end: 0.5).animate(_iconCtrl);
  }

  @override
  void didUpdateWidget(ToolResultCard old) {
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

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.output));
    HapticFeedback.selectionClick();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已复制'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final label = widget.toolName != null
        ? '${widget.toolName} 结果 ($_sizeLabel)'
        : '结果 ($_sizeLabel)';
    final color = widget.isError ? CrossLinkTheme.errorRed : CrossLinkTheme.successGreen;

    return Padding(
      padding: const EdgeInsets.only(bottom: CrossLinkTheme.spaceMd),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(CrossLinkTheme.radiusMd),
        child: Container(
          decoration: BoxDecoration(
            color: CrossLinkTheme.panel.withAlpha(220),
            borderRadius: BorderRadius.circular(CrossLinkTheme.radiusMd),
            border: Border.all(
              color: color.withAlpha(widget.isError ? 120 : 60),
              width: 0.5,
            ),
            boxShadow: CrossLinkTheme.panelShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(width: 4, color: color),
                    Expanded(
                      child: InkWell(
                        onTap: _toggle,
                        borderRadius: BorderRadius.circular(CrossLinkTheme.radiusMd),
                        child: Padding(
                          padding: const EdgeInsets.all(CrossLinkTheme.spaceMd),
                          child: Row(
                            children: [
                              Icon(
                                widget.isError ? Icons.error_outline : Icons.description_outlined,
                                size: 18,
                                color: color,
                              ),
                              const SizedBox(width: CrossLinkTheme.spaceSm),
                              Expanded(
                                child: Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: color,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (widget.toolId != null && widget.toolId!.isNotEmpty)
                                Text(
                                  '#${widget.toolId!.length > 8 ? widget.toolId!.substring(0, 8) : widget.toolId!}',
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontFamily: 'monospace',
                                    color: cs.onSurface.withAlpha(80),
                                  ),
                                ),
                              const SizedBox(width: CrossLinkTheme.spaceSm),
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
              AnimatedSize(
                duration: CrossLinkTheme.durationNormal,
                curve: CrossLinkTheme.curveDefault,
                alignment: Alignment.topCenter,
                child: _expanded
                    ? GestureDetector(
                        onLongPress: _copy,
                        child: Container(
                          width: double.infinity,
                          margin: const EdgeInsets.fromLTRB(
                            CrossLinkTheme.spaceMd,
                            0,
                            CrossLinkTheme.spaceMd,
                            CrossLinkTheme.spaceMd,
                          ),
                          padding: const EdgeInsets.all(CrossLinkTheme.spaceSm),
                          decoration: BoxDecoration(
                            color: CrossLinkTheme.deepSpace.withAlpha(160),
                            borderRadius: BorderRadius.circular(CrossLinkTheme.radiusSm),
                            border: Border.all(
                              color: cs.outlineVariant.withAlpha(40),
                              width: 0.5,
                            ),
                          ),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 200),
                            child: SingleChildScrollView(
                              child: SelectableText(
                            widget.output,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: widget.isError
                                  ? CrossLinkTheme.errorRed.withAlpha(220)
                                  : cs.onSurface.withAlpha(180),
                              height: 1.4,
                            ),
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
      ),
    );
  }
}
