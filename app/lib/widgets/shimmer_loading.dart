import 'package:flutter/material.dart';

/// A shimmer placeholder for loading states. Procedural, no assets.
class ShimmerBox extends StatefulWidget {
  final double width;
  final double height;
  final double borderRadius;
  const ShimmerBox({
    super.key,
    required this.width,
    required this.height,
    this.borderRadius = 8,
  });

  @override
  State<ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<ShimmerBox>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
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
      builder: (context, _) {
        final gradient = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: [0.0, _ctrl.value.clamp(0.0, 0.5) * 2, 1.0],
          colors: [
            Colors.white.withAlpha(8),
            Colors.white.withAlpha(20),
            Colors.white.withAlpha(8),
          ],
        );
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            gradient: gradient,
          ),
        );
      },
    );
  }
}

/// A full card-shaped shimmer placeholder.
class ShimmerCard extends StatelessWidget {
  const ShimmerCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const ShimmerBox(width: 44, height: 44, borderRadius: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const ShimmerBox(width: 120, height: 14, borderRadius: 4),
                  const SizedBox(height: 8),
                  const ShimmerBox(width: 200, height: 12, borderRadius: 4),
                ],
              ),
            ),
            const ShimmerBox(width: 40, height: 12, borderRadius: 4),
          ],
        ),
      ),
    );
  }
}
