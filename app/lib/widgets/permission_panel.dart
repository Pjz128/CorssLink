/// 独立权限侧边栏 — PermissionPanel
///
/// 从消息列表中分离，固定在聊天区域右侧。
/// 不参与滚动，不干扰 TextField 状态，解决 Bug #2 #4。
/// 支持会话信任：勾选后同工具后续自动放行。
import 'dart:async';
import 'package:flutter/material.dart';
import '../models/protocol.dart';
import '../services/http_service.dart';

class PermissionPanel extends StatefulWidget {
  final Map<String, ChoiceRequestEvent> choiceRequests;
  final Set<String> trustedTools;
  final HttpService? http;
  final ValueChanged<String> onChoiceHandled; // requestId 回调

  const PermissionPanel({
    super.key,
    required this.choiceRequests,
    required this.trustedTools,
    required this.http,
    required this.onChoiceHandled,
  });

  @override
  State<PermissionPanel> createState() => _PermissionPanelState();
}

class _PermissionPanelState extends State<PermissionPanel>
    with SingleTickerProviderStateMixin {
  late AnimationController _animCtrl;
  late Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      duration: Duration(milliseconds: 300),
      vsync: this,
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(1.0, 0.0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic));

    // 有请求时滑入，无请求时滑出
    if (widget.choiceRequests.isNotEmpty) _animCtrl.forward();
  }

  @override
  void didUpdateWidget(PermissionPanel old) {
    super.didUpdateWidget(old);
    final wasEmpty = old.choiceRequests.isEmpty;
    final isEmpty = widget.choiceRequests.isEmpty;
    if (wasEmpty && !isEmpty) {
      _animCtrl.forward();
    } else if (!wasEmpty && isEmpty) {
      _animCtrl.reverse();
    }
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.choiceRequests.isEmpty) {
      return const SizedBox(width: 0, height: 0);
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final panelWidth = screenWidth < 500 ? screenWidth * 0.75 : 280.0;

    return SlideTransition(
      position: _slideAnim,
      child: Container(
        width: panelWidth,
        decoration: BoxDecoration(
          color: const Color(0xFF161822),
          border: Border(
            left: BorderSide(color: Colors.white.withAlpha(25)),
          ),
        ),
        child: Column(
          children: [
            // 标题栏
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Colors.white.withAlpha(15)),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.security, size: 18, color: Colors.orange.shade300),
                  const SizedBox(width: 8),
                  Text(
                    '权限请求 (${widget.choiceRequests.length})',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withAlpha(230),
                    ),
                  ),
                  const Spacer(),
                  _buildCountdownIndicator(),
                ],
              ),
            ),
            // 请求列表
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: widget.choiceRequests.length,
                itemBuilder: (ctx, i) {
                  final entry = widget.choiceRequests.entries.elementAt(i);
                  return _PermissionCard(
                    event: entry.value,
                    trustedTools: widget.trustedTools,
                    http: widget.http,
                    onChoiceHandled: widget.onChoiceHandled,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCountdownIndicator() {
    // 取第一个请求的时间戳做倒计时展示
    if (widget.choiceRequests.isEmpty) return const SizedBox.shrink();
    return _CountdownBadge();
  }
}

/// 单张权限卡片（侧边栏版本）
class _PermissionCard extends StatefulWidget {
  final ChoiceRequestEvent event;
  final Set<String> trustedTools;
  final HttpService? http;
  final ValueChanged<String> onChoiceHandled;

  const _PermissionCard({
    required this.event,
    required this.trustedTools,
    required this.http,
    required this.onChoiceHandled,
  });

  @override
  State<_PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<_PermissionCard> {
  bool _expanded = false;
  bool _responded = false;
  bool _sending = false;
  bool _trustChecked = false;

  Color get _toolColor {
    switch (widget.event.toolName) {
      case 'Bash':
        return Colors.orange;
      case 'Write':
        return Colors.blue;
      case 'Edit':
        return Colors.purple;
      default:
        return Colors.grey;
    }
  }

  Future<void> _handleChoice(String behavior) async {
    if (_responded) return;
    setState(() {
      _responded = true;
      _sending = true;
    });

    if (widget.http != null) {
      await widget.http!.sendChoice(
        widget.event.requestId,
        behavior,
        trustSession: behavior == 'allow' && _trustChecked,
      );
    }

    if (behavior == 'allow' && _trustChecked) {
      widget.trustedTools.add(widget.event.toolName);
    }

    widget.onChoiceHandled(widget.event.requestId);
  }

  @override
  Widget build(BuildContext context) {
    final color = _toolColor;
    final evt = widget.event;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1D28),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withAlpha(15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 工具名 + 展开按钮
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Container(
                    width: 4,
                    height: 32,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(
                    evt.toolName == 'Bash'
                        ? Icons.terminal
                        : evt.toolName == 'Write'
                            ? Icons.edit_note
                            : Icons.edit,
                    size: 18,
                    color: color.withAlpha(200),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      evt.toolName,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: Duration(milliseconds: 200),
                    child: Icon(Icons.expand_more,
                        size: 18, color: Colors.white.withAlpha(100)),
                  ),
                ],
              ),
            ),
          ),
          // 可折叠的输入详情
          AnimatedSize(
            duration: Duration(milliseconds: 200),
            child: _expanded
                ? Container(
                    width: double.infinity,
                    margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0E1018),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _formatInput(evt.input),
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: Colors.white.withAlpha(180),
                      ),
                    ),
                  )
                : const SizedBox(height: 0),
          ),
          // 决策理由
          if (evt.decisionReason != null && evt.decisionReason!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Text(
                evt.decisionReason!,
                style: TextStyle(
                    fontSize: 11, color: Colors.white.withAlpha(130)),
              ),
            ),
          // 操作按钮
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: _responded
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_sending)
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white.withAlpha(150),
                          ),
                        )
                      else
                        Icon(Icons.check_circle,
                            size: 16, color: Colors.green.shade300),
                      const SizedBox(width: 6),
                      Text(
                        _sending ? '发送中…' : '已回复',
                        style: TextStyle(
                            fontSize: 12, color: Colors.white.withAlpha(150)),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      // Trust checkbox
                      Row(
                        children: [
                          SizedBox(
                            height: 24,
                            width: 24,
                            child: Checkbox(
                              value: _trustChecked,
                              onChanged: (v) =>
                                  setState(() => _trustChecked = v ?? false),
                              activeColor: Colors.green.shade400,
                              side: BorderSide(
                                  color: Colors.white.withAlpha(80), width: 1),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                          const SizedBox(width: 4),
                          GestureDetector(
                            onTap: () =>
                                setState(() => _trustChecked = !_trustChecked),
                            child: Text(
                              '信任本次会话',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.white.withAlpha(140),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // Allow / Pause / Abort buttons
                      Row(
                        children: [
                          Expanded(
                            child: _buildButton('允许', Colors.green, 'allow'),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: _buildButton('暂停', Colors.orange, 'deny'),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: _buildButton('拒绝', Colors.red, 'abort'),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildButton(String label, Color baseColor, String behavior) {
    final isAllow = behavior == 'allow';
    return InkWell(
      onTap: () => _handleChoice(behavior),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isAllow
              ? Colors.green.withAlpha(30)
              : Colors.red.withAlpha(25),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isAllow
                ? Colors.green.withAlpha(80)
                : Colors.red.withAlpha(60),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: isAllow ? Colors.green.shade300 : Colors.red.shade300,
          ),
        ),
      ),
    );
  }

  String _formatInput(Map<String, dynamic>? input) {
    if (input == null || input.isEmpty) return '(无参数)';
    final b = StringBuffer();
    for (final e in input.entries) {
      final v = e.value.toString();
      b.writeln(
          '${e.key}: ${v.length > 80 ? '${v.substring(0, 80)}…' : v}');
    }
    return b.toString().trimRight();
  }
}

/// 倒计时指示器：展示 60s 倒计时
class _CountdownBadge extends StatefulWidget {
  @override
  State<_CountdownBadge> createState() => _CountdownBadgeState();
}

class _CountdownBadgeState extends State<_CountdownBadge> {
  int _remaining = 60;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(Duration(seconds: 1), (_) {
      if (_remaining > 0) {
        setState(() => _remaining--);
      } else {
        _timer?.cancel();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final urgent = _remaining <= 10;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: urgent
            ? Colors.red.withAlpha(40)
            : Colors.white.withAlpha(15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '${_remaining}s',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: urgent
              ? Colors.red.shade300
              : Colors.white.withAlpha(180),
        ),
      ),
    );
  }
}
