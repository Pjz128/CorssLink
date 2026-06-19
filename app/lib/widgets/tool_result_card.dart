import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Expandable card showing a tool execution result.
/// Matches Claude PC terminal output style with monospace font and copy support.
class ToolResultCard extends StatefulWidget {
  final String output;
  final bool isError;
  final String? toolId;
  final String? toolName;
  const ToolResultCard({
    super.key,
    required this.output,
    this.isError = false,
    this.toolId,
    this.toolName,
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
    _iconCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
    _iconTurns = Tween(begin: 0.0, end: 0.5).animate(_iconCtrl);
  }

  @override
  void dispose() {
    _iconCtrl.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() {
      _expanded = !_expanded;
      if (_expanded) { _iconCtrl.forward(); } else { _iconCtrl.reverse(); }
    });
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.output));
    HapticFeedback.selectionClick();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final label = widget.toolName != null ? '${widget.toolName} 结果 ($_sizeLabel)' : '结果 ($_sizeLabel)';

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        decoration: BoxDecoration(
          color: widget.isError
              ? Colors.red.shade900.withAlpha(30)
              : cs.surfaceContainerHighest.withAlpha(40),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: widget.isError ? Colors.red.shade800 : cs.outlineVariant.withAlpha(80),
            width: 0.5,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: _toggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(children: [
                  Icon(widget.isError ? Icons.error_outline : Icons.description_outlined,
                      size: 14, color: widget.isError ? Colors.red.shade400 : cs.onSurface.withAlpha(120)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(label,
                        style: TextStyle(fontSize: 11, color: widget.isError ? Colors.red.shade300 : cs.onSurface.withAlpha(140)),
                        overflow: TextOverflow.ellipsis),
                  ),
                  if (widget.toolId != null && widget.toolId!.isNotEmpty)
                    Text('#${widget.toolId!.length > 8 ? widget.toolId!.substring(0, 8) : widget.toolId!}',
                        style: TextStyle(fontSize: 9, fontFamily: 'monospace', color: cs.onSurface.withAlpha(80))),
                  const SizedBox(width: 8),
                  AnimatedBuilder(
                    animation: _iconTurns,
                    builder: (_, child) => Transform.rotate(angle: _iconTurns.value * 3.14159, child: child),
                    child: Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 14, color: cs.onSurface.withAlpha(120)),
                  ),
                ]),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _expanded
                  ? GestureDetector(
                      onLongPress: _copy,
                      child: Container(
                        width: double.infinity,
                        margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: cs.surface.withAlpha(180),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: SelectableText(
                          widget.output,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            color: widget.isError ? Colors.red.shade300 : cs.onSurface.withAlpha(180),
                            height: 1.4,
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
