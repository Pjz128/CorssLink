import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../models/pairing.dart';
import '../models/protocol.dart';
import '../services/chat_history_service.dart';
import '../services/settings_service.dart';
import '../services/webrtc_service.dart';
import '../widgets/status_pulse.dart';
import '../widgets/typing_indicator.dart';

class ChatScreen extends StatefulWidget {
  final PairedDevice device;
  final SettingsService settings;
  final String? sessionId; // null = create new session
  final String? preSelectedModel; // pre-select a model before connecting
  const ChatScreen({
    super.key,
    required this.device,
    required this.settings,
    this.sessionId,
    this.preSelectedModel,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  WebRTCService? _rtc;
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final List<_ChatBubble> _bubbles = [];
  _ChatBubble? _streamingBubble;
  String _statusText = '连接中...';
  String _stepLabel = '';
  bool _connecting = true;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  RTCState _state = RTCState.disconnected;
  bool _wasEverConnected = false;
  StreamSubscription? _stepSub;

  List<String> _availableModels = [];
  String _selectedModel = '';
  bool _modelsLoading = false;

  ChatHistoryService? _history;
  late Session _session;
  List<String> _sessionIds = [];
  StreamSubscription? _stateSub;

  @override
  void initState() {
    super.initState();
    _selectedModel = widget.preSelectedModel ?? widget.settings.model;
    _initSession();
  }

  Future<void> _initSession() async {
    _history = await ChatHistoryService.open();
    _refreshSessionList();

    if (widget.sessionId != null) {
      final loaded = _history!.load(widget.sessionId!);
      _session = loaded ?? _history!.create(widget.device.deviceId);
    } else {
      _session = _history!.create(widget.device.deviceId);
    }
    await _history!.save(_session);

    if (_session.messages.isNotEmpty && mounted) {
      setState(() {
        for (final r in _session.messages) {
          _bubbles.add(_ChatBubble(
            role: r.role,
            content: r.content,
            time: DateTime.fromMillisecondsSinceEpoch(r.time),
          ));
        }
      });
    }
    _connect();
  }

  void _refreshSessionList() {
    if (_history == null || !mounted) return;
    setState(() {
      _sessionIds = _history!.listSessions(widget.device.deviceId);
    });
  }

  Future<void> _switchSession(String sessionId) async {
    if (sessionId == _session.id) return;
    await _saveHistory();
    final loaded = _history!.load(sessionId);
    if (loaded == null) return;
    setState(() {
      _session = loaded;
      _bubbles.clear();
      _streamingBubble = null;
      for (final r in _session.messages) {
        _bubbles.add(_ChatBubble(
          role: r.role,
          content: r.content,
          time: DateTime.fromMillisecondsSinceEpoch(r.time),
        ));
      }
    });
    _refreshSessionList();
    _scrollToBottom();
  }

  Future<void> _newSession() async {
    await _saveHistory();
    final s = _history!.create(widget.device.deviceId);
    await _history!.save(s);
    setState(() {
      _session = s;
      _bubbles.clear();
      _streamingBubble = null;
    });
    _refreshSessionList();
  }

  Future<void> _deleteSession(String sessionId) async {
    final s = _history!.load(sessionId);
    final title = s?.title ?? '未知对话';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除对话'),
        content: Text('确定删除「$title」？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _history!.delete(sessionId);
    _refreshSessionList();
    if (sessionId == _session.id) {
      // Current session deleted — switch to latest or create new
      final remaining = _history!.listSessions(widget.device.deviceId);
      if (remaining.isNotEmpty) {
        _switchSession(remaining.first);
      } else {
        _newSession();
      }
    }
  }

  // ---- WebRTC ----

  Future<void> _connect() async {
    // 已连接时禁止重连
    if (_state == RTCState.connected) {
      debugPrint('[RTC] _connect blocked — already connected');
      return;
    }
    _reconnectTimer?.cancel();
    try { await _disposeRTC(); } catch (_) {}
    final rtc = WebRTCService(
      deviceId: widget.device.deviceId,
      agentId: widget.device.agentId,
      serverUrl: widget.settings.serverUrl,
    );
    _stateSub?.cancel();
    debugPrint('[RTC] registering state listener on rtc.state');
    _stateSub = rtc.state.listen((state) {
      debugPrint('[RTC] ChatScreen listener received: $state');
      if (!mounted) return;
      final prevState = _state;
      debugPrint('[RTC] ChatScreen state: $prevState → $state');
      setState(() {
        _state = state;
        switch (state) {
          case RTCState.connecting:
            _statusText = '连接中...';
            _connecting = true;
            break;
          case RTCState.connected:
            _statusText = '已连接';
            _connecting = false;
            _reconnectAttempts = 0;
            _fetchModels();
            break;
          case RTCState.failed:
            _statusText = '连接失败';
            _connecting = false;
            _scheduleReconnect();
            break;
          case RTCState.disconnected:
            _statusText = '已断开';
            _connecting = false;
            _scheduleReconnect();
            break;
        }
        // Insert system bubble only on meaningful reconnection events
        // (not during initial connection, only after we've been connected before)
        if (_wasEverConnected && prevState != state) {
          if (state == RTCState.connecting) {
            _bubbles.add(_ChatBubble(role: 'system', content: '🔄 信使正在重新连接...', time: DateTime.now()));
          } else if (state == RTCState.connected) {
            _bubbles.add(_ChatBubble(role: 'system', content: '✅ 信使已重连', time: DateTime.now()));
          } else if (state == RTCState.failed || state == RTCState.disconnected) {
            _bubbles.add(_ChatBubble(role: 'system', content: '⚠️ 信使连接断开，正在重试...', time: DateTime.now()));
          }
        }
        if (state == RTCState.connected) {
          _wasEverConnected = true;
        }
      });
    });
    rtc.messages.listen(_onDataMessage);
    _stepSub?.cancel();
    _stepSub = rtc.step.listen((s) {
      if (mounted) setState(() => _stepLabel = s.label);
    });
    _rtc = rtc;
    await rtc.connect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectAttempts++;
    final delay = Duration(milliseconds: (_reconnectAttempts * 1500).clamp(1500, 30000));
    _reconnectTimer = Timer(delay, () {
      if (mounted && _state != RTCState.connected) {
        _connect();
      }
    });
  }

  Future<void> _disposeRTC() async {
    debugPrint('[RTC] _disposeRTC called — stack: ${StackTrace.current}');
    _stateSub?.cancel();
    _stateSub = null;
    _stepSub?.cancel();
    _stepSub = null;
    if (_rtc != null) {
      await _rtc!.dispose();
      _rtc = null;
      debugPrint('[RTC] _disposeRTC done');
    }
  }

  void _fetchModels() {
    if (_rtc == null || _modelsLoading || _state != RTCState.connected) return;
    if (mounted) setState(() => _modelsLoading = true);
    try {
      _rtc!.send(_jsonEncode(WireMessage.create(MsgType.listModels, {}).toJson()));
    } catch (e) {
      debugPrint('[RTC] _fetchModels send error: $e');
    }
  }

  void _onDataMessage(String raw) {
    try {
      final wm = decodeWireMessage(raw);
      if (!mounted) return;

      switch (wm.type) {
        case MsgType.chatToken:
          final token = wm.body['token'] as String? ?? '';
          if (mounted) {
            setState(() {
              _streamingBubble ??= _ChatBubble(role: 'assistant', content: '', time: DateTime.now());
              _streamingBubble!.content += token;
            });
          }
          _scrollToBottom();
          break;

        case MsgType.chatDone:
          if (mounted) {
            setState(() {
              if (_streamingBubble != null) {
                _bubbles.add(_streamingBubble!);
                _streamingBubble = null;
              }
            });
          }
          _saveHistory();
          break;

        case MsgType.chatError:
          final errMsg = wm.body['message'] as String? ?? '未知错误';
          if (mounted) {
            setState(() {
              _streamingBubble = null;
              _bubbles.add(_ChatBubble(role: 'error', content: '错误：$errMsg', time: DateTime.now()));
            });
          }
          _saveHistory();
          break;

        case MsgType.listResponse:
          final models = (wm.body['models'] as List?)
                  ?.map((m) => (m as Map<String, dynamic>)['name'] as String? ?? '')
                  .where((n) => n.isNotEmpty)
                  .toList() ?? [];
          if (mounted) {
            setState(() {
              _availableModels = models;
              _modelsLoading = false;
              if (_availableModels.isNotEmpty && !_availableModels.contains(_selectedModel)) {
                _selectedModel = _availableModels.first;
              }
            });
          }
          break;

        case MsgType.pong:
          break;
        default:
          break;
      }
    } catch (e) {
      debugPrint('[RTC] ❌ _onDataMessage error: $e');
    }
  }

  void _sendMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty || _rtc == null || _connecting) return;

    HapticFeedback.lightImpact();

    // Auto-title on first user message
    if (_session.messages.isEmpty && _session.title == '新对话') {
      _session.title = _history!.autoTitle(text);
    }

    setState(() {
      _bubbles.add(_ChatBubble(role: 'user', content: text, time: DateTime.now()));
    });
    _textController.clear();

    _rtc!.send(_jsonEncode(WireMessage.create(MsgType.chatRequest, {
      'model': _selectedModel,
      'messages': [{'role': 'user', 'content': text}],
    }).toJson()));
    _scrollToBottom();
    _saveHistory();
  }

  // ---- History ----

  Future<void> _saveHistory() async {
    if (_history == null) return;
    _session.messages.clear();
    for (final b in _bubbles.where((b) => b.role != 'system')) {
      _session.messages.add(ChatRecord(role: b.role, content: b.content, time: b.time.millisecondsSinceEpoch));
    }
    if (_streamingBubble != null) {
      _session.messages.add(ChatRecord(
          role: _streamingBubble!.role,
          content: _streamingBubble!.content,
          time: _streamingBubble!.time.millisecondsSinceEpoch));
    }
    await _history!.save(_session);
    _refreshSessionList();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _copyMessage(String text) {
    HapticFeedback.selectionClick();
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
    );
  }

  String _fmt(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  // ---- Build ----

  @override
  Widget build(BuildContext context) {
    final canSend = !_connecting && _rtc != null;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.device.deviceName.isNotEmpty ? widget.device.deviceName : widget.device.agentId,
                style: const TextStyle(fontSize: 16)),
            Text(_selectedModel, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
        actions: [
          if (_availableModels.isNotEmpty)
            PopupMenuButton<String>(
              icon: const Icon(Icons.smart_toy, size: 20),
              tooltip: '选择模型',
              onSelected: (m) => setState(() => _selectedModel = m),
              itemBuilder: (_) => _availableModels
                  .map((m) => PopupMenuItem(
                        value: m,
                        child: Row(children: [
                          if (m == _selectedModel) const Icon(Icons.check, size: 16) else const SizedBox(width: 16),
                          const SizedBox(width: 8), Text(m),
                        ]),
                      ))
                  .toList(),
            ),
          IconButton(
            icon: const Icon(Icons.add_comment),
            tooltip: '新建对话',
            onPressed: _newSession,
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '历史对话',
            onPressed: () => _showSessionDrawer(context),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 160),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _state == RTCState.connected
                    ? Colors.green.shade900.withAlpha(150)
                    : _connecting
                        ? Colors.orange.shade900.withAlpha(150)
                        : Colors.grey.shade800.withAlpha(150),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  StatusPulse(
                    connected: _state == RTCState.connected,
                    connecting: _connecting,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      _stepLabel.isNotEmpty ? _stepLabel : _statusText,
                      style: const TextStyle(fontSize: 10),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_bubbles.isEmpty && _streamingBubble == null)
            Expanded(child: _buildWelcome())
          else
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                itemCount: _bubbles.length + (_streamingBubble != null ? 1 : 0),
                itemBuilder: (ctx, i) {
                  final isStreaming = i >= _bubbles.length;
                  final bubble = isStreaming ? _streamingBubble! : _bubbles[i];
                  return _BubbleWidget(
                    bubble: bubble,
                    onCopy: () => _copyMessage(bubble.content),
                    showTime: !isStreaming,
                    timeStr: _fmt(bubble.time),
                  );
                },
              ),
            ),
          const Divider(height: 1),
          _buildInput(canSend),
        ],
      ),
    );
  }

  Widget _buildWelcome() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey.shade700),
            const SizedBox(height: 16),
            Text('已连接到 ${widget.device.deviceName.isNotEmpty ? widget.device.deviceName : widget.device.agentId}',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(_connecting ? '正在建立安全连接...' : '发送消息开始对话',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _buildInput(bool canSend) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              enabled: canSend,
              decoration: InputDecoration(
                hintText: canSend ? '输入消息...' : _statusText,
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              textInputAction: TextInputAction.send,
              onSubmitted: canSend ? (_) => _sendMessage() : null,
              minLines: 1,
              maxLines: 4,
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: canSend ? _sendMessage : null,
            icon: const Icon(Icons.send),
          ),
        ],
      ),
    );
  }

  void _showSessionDrawer(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        final sessions = _sessionIds;
        return StatefulBuilder(builder: (ctx, setSheetState) {
          return DraggableScrollableSheet(
            initialChildSize: 0.5,
            minChildSize: 0.3,
            maxChildSize: 0.85,
            expand: false,
            builder: (ctx, scrollCtrl) {
              if (sessions.isEmpty) {
                return const Center(child: Text('暂无对话记录'));
              }
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Text('对话列表 (${sessions.length})',
                            style: Theme.of(context).textTheme.titleSmall),
                        const Spacer(),
                        FilledButton.tonalIcon(
                          onPressed: () {
                            Navigator.pop(ctx);
                            _newSession();
                          },
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('新建'),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      controller: scrollCtrl,
                      itemCount: sessions.length,
                      itemBuilder: (_, i) {
                        final s = _history!.load(sessions[i]);
                        if (s == null) return const SizedBox.shrink();
                        final isActive = s.id == _session.id;
                        return ListTile(
                          selected: isActive,
                          selectedTileColor:
                              Theme.of(context).colorScheme.primary.withAlpha(30),
                          title: Text(s.title,
                              style: TextStyle(
                                  fontWeight: isActive ? FontWeight.bold : FontWeight.normal)),
                          subtitle: Text(
                            s.lastPreview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          trailing: PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert, size: 18),
                            onSelected: (action) {
                              if (action == 'delete') {
                                _deleteSession(s.id);
                                setSheetState(() {});
                              }
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(value: 'delete', child: Text('删除')),
                            ],
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            _switchSession(s.id);
                          },
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          );
        });
      },
    );
  }

  @override
  void dispose() {
    _saveHistory();
    _reconnectTimer?.cancel();
    _disposeRTC();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

// ---- Chat Bubble Model ----

class _ChatBubble {
  final String role;
  String content;
  final DateTime time;
  _ChatBubble({required this.role, required this.content, required this.time});
}

// ---- Bubble Widget ----

class _BubbleWidget extends StatelessWidget {
  final _ChatBubble bubble;
  final VoidCallback onCopy;
  final bool showTime;
  final String timeStr;
  const _BubbleWidget({
    required this.bubble,
    required this.onCopy,
    required this.showTime,
    required this.timeStr,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = bubble.role == 'user';
    final isError = bubble.role == 'error';
    final isSystem = bubble.role == 'system';

    if (isSystem) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.grey.shade800.withAlpha(80),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              bubble.content,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Colors.grey.shade400,
                    fontStyle: FontStyle.italic,
                  ),
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onLongPress: onCopy,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Column(
          crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Align(
              alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
                decoration: BoxDecoration(
                  color: isError
                      ? Colors.red.shade900
                      : isUser
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16).copyWith(
                    bottomRight: isUser ? const Radius.circular(4) : null,
                    bottomLeft: isUser ? null : const Radius.circular(4),
                  ),
                ),
                child: isUser
                    ? Text(bubble.content,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.white))
                    : isError
                        ? Text(bubble.content, style: Theme.of(context).textTheme.bodyMedium)
                        : _MarkdownBody(content: bubble.content),
              ),
            ),
            if (showTime)
              Padding(
                padding: const EdgeInsets.only(top: 2, left: 4, right: 4),
                child: Text(timeStr,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: Colors.grey.shade600, fontSize: 10)),
              ),
          ],
        ),
      ),
    );
  }
}

// ---- Markdown Widget ----

class _MarkdownBody extends StatelessWidget {
  final String content;
  const _MarkdownBody({required this.content});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return MarkdownBody(
      data: content,
      selectable: true,
      styleSheet: MarkdownStyleSheet(
        p: Theme.of(context).textTheme.bodyMedium,
        code: TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          backgroundColor: isDark ? Colors.white12 : Colors.black12,
          color: isDark ? Colors.green.shade300 : Colors.green.shade800,
        ),
        codeblockDecoration: BoxDecoration(
          color: isDark ? Colors.white10 : Colors.black.withAlpha(15),
          borderRadius: BorderRadius.circular(8),
        ),
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: Colors.grey.shade600, width: 3)),
        ),
        blockquotePadding: const EdgeInsets.only(left: 12),
      ),
    );
  }
}

// ---- Animated Bubble Wrapper ----

class _AnimatedBubble extends StatefulWidget {
  final int index;
  final Widget child;
  const _AnimatedBubble({required this.index, required this.child});

  @override
  State<_AnimatedBubble> createState() => _AnimatedBubbleState();
}

class _AnimatedBubbleState extends State<_AnimatedBubble>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _slide;
  late Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _slide = Tween(begin: 30.0, end: 0.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic),
    );
    _fade = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
    _ctrl.forward();
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
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _slide.value),
          child: Opacity(
            opacity: _fade.value,
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

String _jsonEncode(Map<String, dynamic> map) => jsonEncode(map);
