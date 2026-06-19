import 'package:flutter/material.dart';

/// Collapsible thinking block — shows Claude's internal reasoning.
/// Streams tokens in real-time, auto-expanded while receiving.
/// Now uses theme colors consistently.
class ThinkingBlock extends StatefulWidget {
  final String content;
  final bool isStreaming;
  const ThinkingBlock({super.key, required this.content, this.isStreaming = false});

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock>
    with SingleTickerProviderStateMixin {
  bool _expanded = true;
  late final AnimationController _iconCtrl;
  late final Animation<double> _iconTurns;

  @override
  void initState() {
    super.initState();
    _iconCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
    _iconTurns = Tween(begin: 0.0, end: 0.5).animate(_iconCtrl);
    if (widget.isStreaming) {
      _expanded = true;
      _iconCtrl.forward();
    }
  }

  @override
  void didUpdateWidget(ThinkingBlock old) {
    super.didUpdateWidget(old);
    if (widget.isStreaming && !old.isStreaming) {
      setState(() { _expanded = true; _iconCtrl.forward(); });
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
      if (_expanded) { _iconCtrl.forward(); } else { _iconCtrl.reverse(); }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withAlpha(50),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: cs.outlineVariant.withAlpha(100), width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: _toggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(children: [
                  if (widget.isStreaming)
                    SizedBox(
                      width: 12, height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5, color: cs.primary.withAlpha(150)),
                    )
                  else
                    Icon(Icons.psychology, size: 14, color: cs.onSurface.withAlpha(120)),
                  const SizedBox(width: 6),
                  Text('思考中…',
                      style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(140), fontStyle: FontStyle.italic)),
                  const Spacer(),
                  AnimatedBuilder(
                    animation: _iconTurns,
                    builder: (_, child) => Transform.rotate(angle: _iconTurns.value * 3.14159, child: child),
                    child: Icon(Icons.chevron_right, size: 14, color: cs.onSurface.withAlpha(120)),
                  ),
                ]),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _expanded
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: Text(widget.content,
                          style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(160), fontStyle: FontStyle.italic, height: 1.4)),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}
