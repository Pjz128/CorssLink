import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/protocol.dart';

/// Interactive permission card displayed when Claude needs user approval
/// before executing a tool. Shows the tool name, input details, and
/// Allow / Deny buttons that send the choice back to the agent.
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

class _PermissionCardState extends State<PermissionCard> {
  bool _responded = false;
  bool _sending = false;

  void _handleChoice(String behavior) async {
    if (_responded) return;
    setState(() {
      _responded = true;
      _sending = true;
    });
    await widget.onChoice(widget.event.requestId, behavior);
    if (mounted) {
      setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final event = widget.event;
    final color = _colorForTool(event.toolName, cs);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withAlpha(120), width: 1.5),
      ),
      color: cs.surfaceContainerHighest.withAlpha(130),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: color.withAlpha(30),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.shield_outlined,
                    size: 20,
                    color: color,
                  ),
                ),
                const SizedBox(width: 10),
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
              ],
            ),
            const SizedBox(height: 12),

            // Input preview
            if (event.input != null && event.input!.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cs.onSurface.withAlpha(10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  const JsonEncoder.withIndent('  ').convert(event.input),
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: cs.onSurface.withAlpha(200),
                  ),
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                ),
              ),

            const SizedBox(height: 14),

            // Action buttons
            if (!_responded)
              Row(
                children: [
                  Expanded(
                    child: _ChoiceButton(
                      label: '✓ 允许此次',
                      color: Colors.green,
                      onTap: () => _handleChoice('allow'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ChoiceButton(
                      label: '✗ 拒绝',
                      color: Colors.red,
                      onTap: () => _handleChoice('deny'),
                    ),
                  ),
                ],
              )
            else
              Row(
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
                  const SizedBox(width: 8),
                  Text(
                    _sending ? '发送中…' : '已回复',
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurface.withAlpha(150),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  static Color _colorForTool(String name, ColorScheme cs) {
    switch (name) {
      case 'Bash':
        return Colors.amber.shade300;
      case 'Grep':
        return Colors.green.shade400;
      case 'Read':
        return Colors.blue.shade300;
      case 'Write':
      case 'Edit':
        return Colors.orange.shade300;
      case 'Glob':
        return Colors.purple.shade200;
      case 'WebSearch':
        return Colors.cyan.shade300;
      case 'WebFetch':
        return Colors.teal.shade300;
      default:
        return cs.primary;
    }
  }
}

class _ChoiceButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ChoiceButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: color.withAlpha(25),
          foregroundColor: color,
          side: BorderSide(color: color.withAlpha(100)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.symmetric(vertical: 8),
        ),
        onPressed: onTap,
        child: Text(
          label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
