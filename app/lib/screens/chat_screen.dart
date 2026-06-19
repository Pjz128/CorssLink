import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../models/pairing.dart';
import '../models/protocol.dart';
import '../services/chat_history_service.dart';
import '../services/http_service.dart';
import '../services/settings_service.dart';
import '../widgets/status_pulse.dart';
import '../widgets/thinking_block.dart';
import '../widgets/tool_call_card.dart';
import '../widgets/tool_result_card.dart';
import '../widgets/agent_picker.dart';

class ChatScreen extends StatefulWidget {
  final PairedDevice device;
  final SettingsService settings;
  final String? sessionId;
  final String? preSelectedModel;
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
  HttpService? _http;
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final List<_ChatBubble> _bubbles = [];
  _ChatBubble? _streamingBubble;
  String _statusText = '就绪';
  StreamSubscription? _chatSub;

  List<String> _availableModels = [];
  String _selectedModel = '';
  bool _modelsLoading = false;

  List<AgentInfo> _availableAgents = [];
  String _selectedAgent = '';
  bool _agentsLoading = false;

  // Thinking state (for tracking the active thinking bubble)
  bool _thinkingActive = false;

  // Tool call state
  final Map<String, _ToolCallState> _toolCalls = {};

  ChatHistoryService? _history;
  late Session _session;
  List<String> _sessionIds = [];

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

    final device = widget.device;
    if (device.isHttpV2) {
      _http = HttpService(baseUrl: device.serverUrl, sessionToken: device.sessionToken);
      setState(() => _statusText = '已连接');
      _fetchAgents();
    } else {
      setState(() => _statusText = '请更新到 v2 Agent');
    }
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
      _thinkingActive = false;
      _toolCalls.clear();
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
      _thinkingActive = false;
      _toolCalls.clear();
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
      final remaining = _history!.listSessions(widget.device.deviceId);
      if (remaining.isNotEmpty) {
        _switchSession(remaining.first);
      } else {
        _newSession();
      }
    }
  }

  void _fetchAgents() {
    if (_http == null || _agentsLoading) return;
    if (mounted) setState(() => _agentsLoading = true);
    _http!.fetchAgents().then((agents) {
      if (!mounted) return;
      setState(() {
        _availableAgents = agents;
        _agentsLoading = false;
        if (_availableAgents.isNotEmpty && _selectedAgent.isEmpty) {
          _selectedAgent = _availableAgents.first.type;
          final firstModels = _availableAgents.first.models;
          _availableModels = firstModels.map((m) => m.name).toList();
          if (_availableModels.isNotEmpty && !_availableModels.contains(_selectedModel)) {
            _selectedModel = _availableModels.first;
          }
        }
      });
    }).catchError((e) {
      if (mounted) setState(() => _agentsLoading = false);
      debugPrint('[HTTP] fetchAgents error: $e');
    });
  }

  /// Finalize the current thinking bubble (mark as not streaming).
  void _finalizeThinkingBubble() {
    if (!_thinkingActive) return;
    _thinkingActive = false;
    // Mark the last thinking bubble as not streaming
    for (int i = _bubbles.length - 1; i >= 0; i--) {
      if (_bubbles[i].role == 'thinking') {
        _bubbles[i].isStreaming = false;
        break;
      }
    }
  }

  void _onDataMessage(WireMessage wm) {
    try {
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
                // Attach usage info from chat-done body
                _streamingBubble!.inputTokens = wm.body['inputTokens'] as int?;
                _streamingBubble!.outputTokens = wm.body['outputTokens'] as int?;
                _streamingBubble!.stopReason = wm.body['stopReason'] as String?;
                _bubbles.add(_streamingBubble!);
                _streamingBubble = null;
              }
              _finalizeThinkingBubble();
            });
          }
          _saveHistory();
          break;

        case MsgType.chatError:
          final errMsg = wm.body['message'] as String? ?? '未知错误';
          if (mounted) {
            setState(() {
              _streamingBubble = null;
              _finalizeThinkingBubble();
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
          final agents = (wm.body['agents'] as List?)
                  ?.map((a) => AgentInfo.fromJson(a as Map<String, dynamic>))
                  .toList() ?? [];
          if (mounted) {
            setState(() {
              _availableModels = models;
              if (agents.isNotEmpty) _availableAgents = agents;
              _modelsLoading = false;
              if (_availableModels.isNotEmpty && !_availableModels.contains(_selectedModel)) {
                _selectedModel = _availableModels.first;
              }
            });
          }
          break;

        case MsgType.listAgents:
          final agents = (wm.body['agents'] as List?)
                  ?.map((a) => AgentInfo.fromJson(a as Map<String, dynamic>))
                  .toList() ?? [];
          if (mounted) {
            setState(() {
              _availableAgents = agents;
              _agentsLoading = false;
              if (_availableAgents.isNotEmpty && _selectedAgent.isEmpty) {
                _selectedAgent = _availableAgents.first.type;
                final firstModels = _availableAgents.first.models;
                _availableModels = firstModels.map((m) => m.name).toList();
                if (_availableModels.isNotEmpty && !_availableModels.contains(_selectedModel)) {
                  _selectedModel = _availableModels.first;
                }
              }
            });
          }
          break;

        case MsgType.thinking:
          final token = wm.body['token'] as String? ?? '';
          if (mounted && token.isNotEmpty) {
            setState(() {
              _thinkingActive = true;
              // Append to last thinking bubble or create new one
              if (_bubbles.isNotEmpty && _bubbles.last.role == 'thinking') {
                _bubbles.last.content += token;
              } else {
                _bubbles.add(_ChatBubble(role: 'thinking', content: token, time: DateTime.now(), isStreaming: true));
              }
            });
          }
          _scrollToBottom();
          break;

        case MsgType.toolUse:
          final tId = wm.body['id'] as String? ?? '';
          final tName = wm.body['name'] as String? ?? '';
          if (tId.isNotEmpty && mounted) {
            setState(() {
              _toolCalls[tId] = _ToolCallState(name: tName, status: _ToolStatus.running);
              _finalizeThinkingBubble();
            });
            _bubbles.add(_ChatBubble(role: 'tool_call', content: tId, time: DateTime.now(), toolId: tId));
          }
          _scrollToBottom();
          break;

        case MsgType.toolInput:
          final tId = wm.body['id'] as String? ?? '';
          if (tId.isNotEmpty && mounted) {
            setState(() {
              _toolCalls[tId]?.input = wm.body['input'];
            });
          }
          break;

        case MsgType.toolResult:
          final tId = wm.body['id'] as String? ?? '';
          final output = wm.body['output'] as String? ?? '';
          final isError = wm.body['isError'] as bool? ?? false;
          if (tId.isNotEmpty && mounted) {
            setState(() {
              _toolCalls[tId]?.status = isError ? _ToolStatus.error : _ToolStatus.done;
              _toolCalls[tId]?.output = output;
            });
            _bubbles.add(_ChatBubble(role: 'tool_result', content: output, time: DateTime.now(), toolId: tId));
          }
          break;

        case MsgType.pong:
          break;
        default:
          break;
      }
    } catch (e) {
      debugPrint('[RTC] _onDataMessage error: $e');
    }
  }

  void _sendMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty || _http == null) return;

    HapticFeedback.lightImpact();

    if (_session.messages.isEmpty && _session.title == '新对话') {
      _session.title = _history!.autoTitle(text);
    }

    setState(() {
      _bubbles.add(_ChatBubble(role: 'user', content: text, time: DateTime.now()));
    });
    _textController.clear();

    // Reset thinking/tool state for new turn
    _thinkingActive = false;
    _toolCalls.clear();

    _chatSub?.cancel();
    _chatSub = _http!.chatStream(
      text,
      agent: _selectedAgent.isNotEmpty ? _selectedAgent : null,
      model: _selectedModel,
    ).listen(
      (wm) => _onDataMessage(wm),
      onError: (e) {
        if (mounted) {
          setState(() {
            _streamingBubble = null;
            _bubbles.add(_ChatBubble(role: 'error', content: '错误：$e', time: DateTime.now()));
          });
          _saveHistory();
        }
      },
      onDone: () => _saveHistory(),
    );

    _scrollToBottom();
    _saveHistory();
  }

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

  @override
  Widget build(BuildContext context) {
    final canSend = _http != null;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.device.deviceName.isNotEmpty ? widget.device.deviceName : widget.device.agentId,
                style: const TextStyle(fontSize: 16),
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                _selectedModel.isNotEmpty ? _selectedModel : '选择模型',
                style: TextStyle(fontSize: 12, color: cs.onSurface.withAlpha(150)),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
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
            padding: const EdgeInsets.only(right: 12),
            child: Tooltip(
              message: _statusText,
              child: StatusPulse(connected: canSend, connecting: false),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Agent picker
          if (_availableAgents.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: AgentPicker(
                agents: _availableAgents,
                selectedAgent: _selectedAgent.isNotEmpty ? _selectedAgent : null,
                selectedModel: _selectedModel,
                onChanged: (sel) {
                  setState(() {
                    _selectedAgent = sel.$1;
                    _selectedModel = sel.$2;
                    _availableModels = _availableAgents
                        .firstWhere((a) => a.type == sel.$1,
                            orElse: () => AgentInfo(type: '', label: '', models: []))
                        .models
                        .map((m) => m.name)
                        .toList();
                  });
                },
              ),
            ),
          // Message list (thinking is now part of _bubbles)
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
                  // For thinking bubbles, the last one is streaming while _thinkingActive
                  final bubbleIsStreaming = isStreaming ||
                      (bubble.role == 'thinking' && i == _bubbles.length - 1 && _thinkingActive);
                  return _AnimatedBubble(
                    index: i,
                    key: ValueKey('${bubble.role}-${bubble.time.millisecondsSinceEpoch}-$i'),
                    child: _BubbleWidget(
                      bubble: bubble,
                      onCopy: () => _copyMessage(bubble.content),
                      showTime: !isStreaming,
                      timeStr: _fmt(bubble.time),
                      toolCalls: _toolCalls,
                      isStreamingBubble: bubbleIsStreaming,
                    ),
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
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline, size: 64, color: cs.onSurface.withAlpha(100)),
            const SizedBox(height: 16),
            Text('已连接到 ${widget.device.deviceName.isNotEmpty ? widget.device.deviceName : widget.device.agentId}',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('发送消息开始对话',
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
              decoration: const InputDecoration(
                hintText: '输入消息...',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
    _chatSub?.cancel();
    _http?.dispose();
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
  final String? toolId;
  bool isStreaming;
  int? inputTokens;
  int? outputTokens;
  String? stopReason;
  _ChatBubble({required this.role, required this.content, required this.time, this.toolId, this.isStreaming = false});
}

// ---- Tool Call State ----

enum _ToolStatus { running, done, error }

class _ToolCallState {
  final String name;
  _ToolStatus status;
  dynamic input;
  String? output;
  _ToolCallState({required this.name, required this.status});
}

// ---- Bubble Widget ----

class _BubbleWidget extends StatelessWidget {
  final _ChatBubble bubble;
  final VoidCallback onCopy;
  final bool showTime;
  final String timeStr;
  final Map<String, _ToolCallState>? toolCalls;
  final bool isStreamingBubble;
  const _BubbleWidget({
    required this.bubble,
    required this.onCopy,
    required this.showTime,
    required this.timeStr,
    this.toolCalls,
    this.isStreamingBubble = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isUser = bubble.role == 'user';
    final isError = bubble.role == 'error';
    final isSystem = bubble.role == 'system';
    final isToolCall = bubble.role == 'tool_call';
    final isToolResult = bubble.role == 'tool_result';
    final isThinking = bubble.role == 'thinking';

    // System message
    if (isSystem) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withAlpha(80),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              bubble.content,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: cs.onSurface.withAlpha(140),
                    fontStyle: FontStyle.italic,
                  ),
            ),
          ),
        ),
      );
    }

    // Thinking block (inside message list)
    if (isThinking) {
      return ThinkingBlock(
        content: bubble.content,
        isStreaming: isStreamingBubble,
      );
    }

    // Tool call card (wired to actual _toolCalls data)
    if (isToolCall) {
      final tId = bubble.toolId ?? bubble.content;
      final ts = toolCalls?[tId];
      return ToolCallCard(
        id: tId,
        name: ts?.name ?? '工具调用',
        input: ts?.input is Map ? Map<String, dynamic>.from(ts!.input as Map) : null,
        resultSummary: ts?.output,
        isError: ts?.status == _ToolStatus.error,
      );
    }

    // Tool result card
    if (isToolResult) {
      final tId = bubble.toolId ?? '';
      final ts = toolCalls?[tId];
      return ToolResultCard(
        output: bubble.content,
        isError: ts?.status == _ToolStatus.error,
        toolId: tId,
        toolName: ts?.name,
      );
    }

    // User / assistant / error bubble
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
                      ? cs.error.withAlpha(180)
                      : isUser
                          ? cs.primary
                          : cs.surfaceContainerHighest,
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
            // Timestamp + usage footer
            if (showTime)
              Padding(
                padding: const EdgeInsets.only(top: 2, left: 4, right: 4),
                child: _buildFooter(context, cs),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter(BuildContext context, ColorScheme cs) {
    final parts = <String>[];
    // Usage info for assistant responses
    if (bubble.role == 'assistant') {
      if (bubble.inputTokens != null && bubble.inputTokens! > 0) {
        parts.add('↑${_fmtTokens(bubble.inputTokens!)}');
      }
      if (bubble.outputTokens != null && bubble.outputTokens! > 0) {
        parts.add('↓${_fmtTokens(bubble.outputTokens!)}');
      }
      if (bubble.stopReason != null && bubble.stopReason!.isNotEmpty) {
        parts.add(bubble.stopReason!);
      }
    }
    if (parts.isNotEmpty) parts.add('·');
    parts.add(timeStr);

    return Text(
      parts.join(' '),
      style: Theme.of(context)
          .textTheme
          .labelSmall
          ?.copyWith(color: cs.onSurface.withAlpha(100), fontSize: 10),
    );
  }

  String _fmtTokens(int n) {
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return n.toString();
  }
}

// ---- Markdown Widget ----

class _MarkdownBody extends StatelessWidget {
  final String content;
  const _MarkdownBody({required this.content});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    return MarkdownBody(
      data: content,
      selectable: true,
      styleSheet: MarkdownStyleSheet(
        p: Theme.of(context).textTheme.bodyMedium,
        code: TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          backgroundColor: cs.onSurface.withAlpha(20),
          color: isDark ? Colors.green.shade300 : Colors.green.shade800,
        ),
        codeblockDecoration: BoxDecoration(
          color: cs.onSurface.withAlpha(10),
          borderRadius: BorderRadius.circular(8),
        ),
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: cs.onSurface.withAlpha(80), width: 3)),
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
  const _AnimatedBubble({required this.index, required this.child, super.key});

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
