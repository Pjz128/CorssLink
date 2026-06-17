import 'dart:math';
import 'package:flutter/material.dart';

/// States the messenger orb can represent.
enum MessengerState { offline, connecting, connected }

/// Animated messenger orb — a glowing sphere with pulse rings that represents
/// the connection state of the agent. Pure procedural animation, no assets.
class AnimatedMessenger extends StatefulWidget {
  final MessengerState state;
  final double size;
  final String? agentName;

  const AnimatedMessenger({
    super.key,
    this.state = MessengerState.offline,
    this.size = 100,
    this.agentName,
  });

  @override
  State<AnimatedMessenger> createState() => _AnimatedMessengerState();
}

class _AnimatedMessengerState extends State<AnimatedMessenger>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _breathe;
  late Animation<double> _glow;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    _breathe = Tween(begin: 1.0, end: 1.08).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
    _glow = Tween(begin: 0.4, end: 0.8).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
    _ctrl.repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Color get _baseColor {
    switch (widget.state) {
      case MessengerState.connected:
        return Colors.green;
      case MessengerState.connecting:
        return Colors.orange;
      case MessengerState.offline:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final baseColor = _baseColor;
        return SizedBox(
          width: widget.size * 1.4,
          height: widget.size * 1.4,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Outer glow ring
              CustomPaint(
                size: Size(widget.size * 1.3, widget.size * 1.3),
                painter: _GlowRingPainter(
                  color: baseColor.withAlpha((80 * _glow.value).round()),
                  radius: widget.size * 0.6,
                ),
              ),
              // Middle pulse ring
              if (widget.state != MessengerState.offline)
                CustomPaint(
                  size: Size(widget.size * 1.15, widget.size * 1.15),
                  painter: _PulseRingPainter(
                    color: baseColor.withAlpha((60 * _glow.value).round()),
                    radius: widget.size * 0.5,
                    progress: _ctrl.value,
                  ),
                ),
              // Main orb
              Transform.scale(
                scale: _breathe.value,
                child: Container(
                  width: widget.size * 0.7,
                  height: widget.size * 0.7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        baseColor.withAlpha(220),
                        baseColor.withAlpha(80),
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: baseColor.withAlpha((100 * _glow.value).round()),
                        blurRadius: 20 * _glow.value,
                        spreadRadius: 4 * _glow.value,
                      ),
                    ],
                  ),
                  child: Center(
                    child: Icon(
                      _stateIcon(),
                      color: Colors.white.withAlpha(220),
                      size: widget.size * 0.3,
                    ),
                  ),
                ),
              ),
              // Particles orbiting (connected only)
              if (widget.state == MessengerState.connected)
                ...List.generate(6, (i) {
                  final angle = (i / 6) * 2 * pi + (_ctrl.value * 2 * pi);
                  return Transform.translate(
                    offset: Offset(
                      cos(angle) * widget.size * 0.45,
                      sin(angle) * widget.size * 0.45,
                    ),
                    child: Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: baseColor.withAlpha(180),
                      ),
                    ),
                  );
                }),
            ],
          ),
        );
      },
    );
  }

  IconData _stateIcon() {
    switch (widget.state) {
      case MessengerState.connected:
        return Icons.auto_awesome;
      case MessengerState.connecting:
        return Icons.sync;
      case MessengerState.offline:
        return Icons.power_settings_new;
    }
  }
}

class _GlowRingPainter extends CustomPainter {
  final Color color;
  final double radius;
  _GlowRingPainter({required this.color, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawCircle(Offset(size.width / 2, size.height / 2), radius, paint);
  }

  @override
  bool shouldRepaint(covariant _GlowRingPainter old) =>
      color != old.color || radius != old.radius;
}

class _PulseRingPainter extends CustomPainter {
  final Color color;
  final double radius;
  final double progress;
  _PulseRingPainter({
    required this.color,
    required this.radius,
    required this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      radius * (0.8 + 0.3 * progress),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _PulseRingPainter old) =>
      color != old.color || radius != old.radius || progress != old.progress;
}
