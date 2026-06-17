import 'package:flutter/material.dart';

/// Animated connection status dot with optional pulse ring.
class StatusPulse extends StatefulWidget {
  final bool connected;
  final bool connecting;
  final bool showLabel;
  final String? label;
  const StatusPulse({
    super.key,
    this.connected = false,
    this.connecting = false,
    this.showLabel = false,
    this.label,
  });

  @override
  State<StatusPulse> createState() => _StatusPulseState();
}

class _StatusPulseState extends State<StatusPulse>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _pulse = Tween(begin: 1.0, end: 2.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
    if (widget.connected || widget.connecting) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(covariant StatusPulse old) {
    super.didUpdateWidget(old);
    if (widget.connected || widget.connecting) {
      if (!_ctrl.isAnimating) _ctrl.repeat();
    } else {
      _ctrl.stop();
      _ctrl.reset();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Color get _color {
    if (widget.connected) return Colors.green;
    if (widget.connecting) return Colors.orange;
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) {
            final active = widget.connected || widget.connecting;
            return SizedBox(
              width: 20,
              height: 20,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Pulse ring
                  if (active)
                    Transform.scale(
                      scale: _pulse.value,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _color.withAlpha((60 * (2 - _pulse.value)).round()),
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  // Core dot
                  Container(
                    width: active ? 10 : 8,
                    height: active ? 10 : 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _color,
                      boxShadow: active
                          ? [BoxShadow(color: _color.withAlpha(80), blurRadius: 6, spreadRadius: 1)]
                          : null,
                    ),
                  ),
                  if (widget.connecting)
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: _color.withAlpha(120),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
        if (widget.showLabel && widget.label != null) ...[
          const SizedBox(width: 6),
          Text(
            widget.label!,
            style: TextStyle(
              fontSize: 12,
              color: _color.withAlpha(200),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }
}
