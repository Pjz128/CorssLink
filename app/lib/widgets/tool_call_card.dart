import 'dart:convert';
import 'package:flutter/material.dart';

/// A collapsible card showing a Claude tool call (e.g. Bash, Read, Grep).
/// Matches Claude PC terminal output style with per-tool color accents.
class ToolCallCard extends StatefulWidget {
  final String id;
  final String name;
  final Map<String, dynamic>? input;
  final String? resultSummary;
  final bool isError;
  const ToolCallCard({
    super.key,
    required this.id,
    required this.name,
    this.input,
    this.resultSummary,
    this.isError = false,
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
      duration: const Duration(milliseconds: 200),
    );
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
      if (_expanded) {
        _iconCtrl.forward();
      } else {
        _iconCtrl.reverse();
      }
    });
  }

  static Color _colorForTool(String name, ColorScheme cs) {
    switch (name) {
      case 'Bash': return Colors.amber.shade300;
      case 'Grep': return Colors.green.shade400;
      case 'Read': return Colors.blue.shade300;
      case 'Write': case 'Edit': return Colors.orange.shade300;
      case 'Glob': return Colors.purple.shade300;
      case 'WebSearch': return Colors.cyan.shade300;
      case 'WebFetch': return Colors.teal.shade300;
      case 'Task': return Colors.pink.shade300;
      default: return cs.primary;
    }
  }

  static IconData _iconForTool(String name) {
    switch (name) {
      case 'Read': return Icons.menu_book;
      case 'Write': case 'Edit': return Icons.edit_note;
      case 'Bash': return Icons.terminal;
      case 'Grep': return Icons.search;
      case 'Glob': return Icons.folder_open;
      case 'WebSearch': return Icons.public;
      case 'WebFetch': return Icons.download;
      case 'Task': return Icons.assignment;
      default: return Icons.build;
    }
  }

  String _formattedInput() {
    if (widget.input == null || widget.input!.isEmpty) return '';
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(widget.input);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final toolColor = _colorForTool(widget.name, cs);
    final hasDetails = widget.input != null && widget.input!.isNotEmpty;
    final hasResult = widget.resultSummary != null && widget.resultSummary!.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withAlpha(40),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: widget.isError ? Colors.red.shade700 : cs.outlineVariant.withAlpha(60),
            width: 0.5,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: (hasDetails || hasResult) ? _toggle : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    Icon(_iconForTool(widget.name), size: 14, color: toolColor),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        widget.name,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: toolColor),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    if (widget.id.isNotEmpty)
                      Text(
                        widget.id.length > 8 ? '#${widget.id.substring(0, 8)}' : '#${widget.id}',
                        style: TextStyle(fontSize: 9, fontFamily: 'monospace', color: cs.onSurface.withAlpha(80)),
                      ),
                    const SizedBox(width: 6),
                    if (widget.resultSummary == null && !widget.isError)
                      SizedBox(
                        width: 10, height: 10,
                        child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.amber.shade300),
                      )
                    else
                      Icon(
                        widget.isError ? Icons.error_outline : Icons.check_circle_outline,
                        size: 14,
                        color: widget.isError ? Colors.red.shade400 : Colors.green.shade400,
                      ),
                    if (hasDetails || hasResult) ...[
                      const SizedBox(width: 4),
                      AnimatedBuilder(
                        animation: _iconTurns,
                        builder: (_, child) => Transform.rotate(angle: _iconTurns.value * 3.14159, child: child),
                        child: Icon(Icons.chevron_right, size: 14, color: cs.onSurface.withAlpha(120)),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _expanded && hasDetails
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: cs.surface.withAlpha(120),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: SelectableText(
                          _formattedInput(),
                          style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: cs.onSurface.withAlpha(180), height: 1.4),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            if (_expanded && hasResult)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Text(widget.resultSummary!, maxLines: 3, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(140))),
              ),
          ],
        ),
      ),
    );
  }
}
