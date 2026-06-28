import 'package:flutter/material.dart';

import '../theme/crosslink_theme.dart';

/// 流式响应时的“Agent 正在输入”指示器。
///
/// 三个小点依次缩放，模拟终端光标闪烁。
class TypingIndicator extends StatefulWidget {
  final String? label;
  const TypingIndicator({super.key, this.label});

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with TickerProviderStateMixin {
  late final List<AnimationController> _controllers;
  late final List<Animation<double>> _scales;

  @override
  void initState() {
    super.initState();
    _controllers = List.generate(
      3,
      (i) => AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 400),
      ),
    );
    _scales = _controllers
        .map((c) => Tween(begin: 0.6, end: 1.2)
            .animate(CurvedAnimation(parent: c, curve: Curves.easeInOut)))
        .toList();

    _stagger();
  }

  Future<void> _stagger() async {
    while (mounted) {
      for (var i = 0; i < _controllers.length; i++) {
        await Future.delayed(const Duration(milliseconds: 160));
        if (!mounted) return;
        _controllers[i].forward();
      }
      await Future.delayed(const Duration(milliseconds: 200));
      for (var i = 0; i < _controllers.length; i++) {
        if (!mounted) return;
        _controllers[i].reverse();
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: CrossLinkTheme.sMd),
        padding: const EdgeInsets.symmetric(
          horizontal: CrossLinkTheme.sMd,
          vertical: CrossLinkTheme.sSm,
        ),
        decoration: BoxDecoration(
          color: CrossLinkTheme.surface.withAlpha(180),
          borderRadius: BorderRadius.circular(CrossLinkTheme.rLg),
          border: Border.all(
            color: cs.outlineVariant.withAlpha(50),
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...List.generate(3, (i) {
              return AnimatedBuilder(
                animation: _controllers[i],
                builder: (_, __) => Transform.scale(
                  scale: _scales[i].value,
                  child: Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.symmetric(horizontal: 2.5),
                    decoration: BoxDecoration(
                      color: CrossLinkTheme.accent,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: CrossLinkTheme.accent.withAlpha(100),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
            if (widget.label != null) ...[
              const SizedBox(width: CrossLinkTheme.sSm),
              Text(
                widget.label!,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withAlpha(140),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
