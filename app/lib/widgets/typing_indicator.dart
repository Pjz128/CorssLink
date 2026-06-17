import 'package:flutter/material.dart';

/// Animated bouncing dots indicating the AI is "thinking".
class TypingIndicator extends StatefulWidget {
  final Color? color;
  final double dotSize;
  const TypingIndicator({super.key, this.color, this.dotSize = 6});

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dotColor =
        widget.color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12).copyWith(
          bottomLeft: const Radius.circular(4),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          final delay = i * 0.2;
          final t = (_ctrl.value - delay).clamp(0.0, 1.0);
          final bounce = _bounceCurve(t);
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: widget.dotSize * 0.4),
            child: Transform.translate(
              offset: Offset(0, -bounce * 6),
              child: Container(
                width: widget.dotSize,
                height: widget.dotSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dotColor.withAlpha(140 + (bounce * 80).round()),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  double _bounceCurve(double t) {
    if (t <= 0.3) return t / 0.3;
    if (t <= 0.6) return (0.6 - t) / 0.3;
    return 0;
  }
}
