import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Connection states for the UI.
enum RTCState { disconnected, connecting, connected, failed }

/// Granular connection steps shown to user.
enum ConnectionStep {
  idle('就绪'),
  signalConnecting('连接信令服务器...'),
  signalConnected('信令服务器已连接'),
  peerCreating('创建对等连接...'),
  peerCreated('对等连接已创建'),
  offerSending('发送连接请求...'),
  offerSent('等待 Agent 回应...'),
  answerReceived('收到 Agent 回应'),
  iceChecking('建立加密通道...'),
  iceConnected('加密通道已建立'),
  dcOpen('数据通道已就绪'),
  connected('已连接'),
  failed('连接失败'),
  timeout('连接超时'),
  ;

  final String label;
  const ConnectionStep(this.label);
}

/// Manages a WebRTC peer connection to a CrossLink Agent via the signal server.
class WebRTCService {
  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  WebSocketChannel? _signal;
  StreamSubscription? _signalSub;
  StreamSubscription? _dcStateSub;
  StreamSubscription? _dcMsgSub;

  final String deviceId;
  final String agentId;
  final String serverUrl;

  static int _nextId = 0;
  final int _id = ++_nextId;
  String get logPrefix => '[RTC#$_id]';

  final _messageController = StreamController<String>.broadcast();
  final _stateController = StreamController<RTCState>.broadcast();
  final _stepController = StreamController<ConnectionStep>.broadcast();

  /// Stream of incoming DataChannel text messages.
  Stream<String> get messages => _messageController.stream;

  /// Stream of connection state changes.
  Stream<RTCState> get state => _stateController.stream;

  /// Stream of granular connection steps for user display.
  Stream<ConnectionStep> get step => _stepController.stream;

  bool _disposed = false;
  Timer? _connectTimeout;
  Timer? _keepaliveTimer;
  RTCState _state = RTCState.disconnected;
  RTCState get currentState => _state;

  WebRTCService({
    required this.deviceId,
    required this.agentId,
    required this.serverUrl,
  });

  /// Full connect flow with diagnostic timing.
  Future<void> connect() async {
    final t0 = DateTime.now();
    _setState(RTCState.connecting);
    _emitStep(ConnectionStep.signalConnecting);
    debugPrint('[RTC$_id] connect() started → ${_fmt(DateTime.now())}');

    // Connection timeout: 30s covers TURN relay + ICE negotiation.
    _connectTimeout?.cancel();
    _connectTimeout = Timer(const Duration(seconds: 30), () {
      if (_state == RTCState.connecting) {
        final elapsed = DateTime.now().difference(t0).inMilliseconds;
        debugPrint('[RTC$_id] ❌ timeout after ${elapsed}ms');
        _emitStep(ConnectionStep.timeout);
        _setState(RTCState.failed);
      }
    });

    try {
      // 1. Signal WebSocket
      final t1 = DateTime.now();
      final wsUrl = _signalUrl();
      debugPrint('[RTC$_id] WS connecting → $wsUrl');
      _signal = WebSocketChannel.connect(Uri.parse(wsUrl));
      await _signal!.ready;
      debugPrint('[RTC$_id] ✓ WS connected (${_since(t1)}ms)');
      _emitStep(ConnectionStep.signalConnected);

      _signalSub = _signal!.stream.listen(
        _onSignalMessage,
        onError: (e) {
          debugPrint('[RTC$_id] WS error: $e');
          _setState(RTCState.failed);
        },
        onDone: () {
          debugPrint('[RTC$_id] WS closed, state=$_state');
          if (_state != RTCState.connected) _setState(RTCState.failed);
        },
      );

      // Keepalive: send ping every 25s so server's 60s read deadline never fires.
      _keepaliveTimer?.cancel();
      _keepaliveTimer = Timer.periodic(const Duration(seconds: 25), (_) {
        _sendSignal({'type': 'ping', 'to': 'hub'});
      });

      // 2. Create RTCPeerConnection — TURN only (no STUN, blocked in CN)
      _emitStep(ConnectionStep.peerCreating);
      final t2 = DateTime.now();
      _pc = await createPeerConnection({
        'iceServers': [
          {
            'urls': 'turn:45.197.144.16:3478?transport=tcp',
            'username': 'turnuser',
            'credential': 'crosslinkpass123',
          },
        ],
        'iceTransportPolicy': 'all', // try TURN first, fallback to host
        'iceCandidatePoolSize': 0,
      });
      debugPrint('[RTC$_id] ✓ PC created (${_since(t2)}ms)');
      _emitStep(ConnectionStep.peerCreated);

      _pc!.onIceCandidate = (candidate) {
        if (candidate.candidate == null || candidate.candidate!.isEmpty) {
          debugPrint('[RTC$_id] ICE gathering complete');
          return;
        }
        _sendSignal({
          'type': 'candidate',
          'to': agentId,
          'iceCandidate': {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        });
      };

      _pc!.onIceConnectionState = (state) {
        debugPrint('[RTC$_id] ICE state → $state');
        if (state == RTCIceConnectionState.RTCIceConnectionStateChecking) {
          _emitStep(ConnectionStep.iceChecking);
        } else if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
                   state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          _emitStep(ConnectionStep.iceConnected);
        } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
                   state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
          _setState(RTCState.failed);
        }
      };

      _pc!.onDataChannel = (dc) {
        _dc = dc;
        _setupDataChannel(dc);
      };

      // 3. Create DataChannel + offer
      final t3 = DateTime.now();
      final init = RTCDataChannelInit()
        ..ordered = true
        ..negotiated = false;
      _dc = await _pc!.createDataChannel('crosslink-poc', init);
      _setupDataChannel(_dc!);
      debugPrint('[RTC$_id] ✓ DC created (${_since(t3)}ms)');

      _emitStep(ConnectionStep.offerSending);
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      debugPrint('[RTC$_id] ✓ offer sent (${_since(t3)}ms total DC+offer)');
      _emitStep(ConnectionStep.offerSent);
      _sendSignal({
        'type': 'offer',
        'to': agentId,
        'sdp': offer.sdp,
        'typeSdp': 'offer',
      });

      debugPrint('[RTC$_id] ===== connection setup done in ${_since(t0)}ms =====');
    } catch (e) {
      debugPrint('[RTC$_id] ❌ exception: $e');
      _emitStep(ConnectionStep.failed);
      _setState(RTCState.failed);
    }
  }

  /// Send a text message over the DataChannel.
  void send(String text) {
    if (_dc?.state == RTCDataChannelState.RTCDataChannelOpen) {
      _dc!.send(RTCDataChannelMessage(text));
    }
  }

  void _setupDataChannel(RTCDataChannel dc) {
    dc.onMessage = (msg) {
      if (!msg.isBinary && !_messageController.isClosed) {
        _messageController.add(msg.text);
      }
    };

    dc.onDataChannelState = (state) {
      debugPrint('[RTC$_id] DC state → $state');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _emitStep(ConnectionStep.dcOpen);
        _setState(RTCState.connected);
      } else if (state == RTCDataChannelState.RTCDataChannelClosed ||
                 state == RTCDataChannelState.RTCDataChannelClosing) {
        _setState(RTCState.disconnected);
      }
    };
  }

  void _onSignalMessage(dynamic raw) {
    try {
      final msg = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = msg['type'] as String?;
      debugPrint('[RTC$_id] ← signal: $type');
      switch (type) {
        case 'answer':
          _handleAnswer(msg);
        case 'candidate':
          _handleCandidate(msg);
        case 'offer':
          _handleOffer(msg);
      }
    } catch (_) {}
  }

  Future<void> _handleAnswer(Map<String, dynamic> msg) async {
    final sdp = msg['sdp'] as String?;
    if (sdp == null) return;
    debugPrint('[RTC$_id] ✓ got answer, setting remote description');
    _emitStep(ConnectionStep.answerReceived);
    await _pc?.setRemoteDescription(
      RTCSessionDescription(sdp, 'answer'),
    );
  }

  Future<void> _handleOffer(Map<String, dynamic> msg) async {
    final sdp = msg['sdp'] as String?;
    final from = msg['from'] as String?;
    if (sdp == null) return;
    await _pc?.setRemoteDescription(
      RTCSessionDescription(sdp, 'offer'),
    );
    final answer = await _pc?.createAnswer();
    if (answer == null) return;
    await _pc?.setLocalDescription(answer);
    _sendSignal({
      'type': 'answer',
      'to': from ?? agentId,
      'sdp': answer.sdp,
      'typeSdp': 'answer',
    });
  }

  Future<void> _handleCandidate(Map<String, dynamic> msg) async {
    final cand = msg['iceCandidate'] as Map<String, dynamic>?;
    if (cand == null) return;
    await _pc?.addCandidate(RTCIceCandidate(
      cand['candidate'] as String? ?? '',
      cand['sdpMid'] as String?,
      cand['sdpMLineIndex'] as int?,
    ));
  }

  void _sendSignal(Map<String, dynamic> data) {
    if (_signal != null) {
      _signal!.sink.add(jsonEncode(data));
    }
  }

  String _signalUrl() {
    final clean = serverUrl.endsWith('/')
        ? serverUrl.substring(0, serverUrl.length - 1)
        : serverUrl;
    // Append random suffix to prevent stale peer state on signal server
    final uniqueId = '${deviceId}_${DateTime.now().millisecondsSinceEpoch}';
    return '$clean/ws?peer=$uniqueId';
  }

  void _emitStep(ConnectionStep s) {
    if (!_stepController.isClosed) _stepController.add(s);
  }

  void _setState(RTCState state) {
    debugPrint('[RTC$_id] _setState($state) disposed=$_disposed closed=${_stateController.isClosed}');
    if (state == RTCState.connected || state == RTCState.failed) {
      _connectTimeout?.cancel();
      _connectTimeout = null;
    }
    _state = state;
    try {
      _stateController.add(state);
    } catch (_) {
      debugPrint('[RTC$_id] _setState add failed (controller closed)');
    }
  }

  Future<void> dispose() async {
    debugPrint('[RTC$_id] WebRTCService.dispose() called — stack: ${StackTrace.current}');
    _disposed = true;
    _connectTimeout?.cancel();
    _connectTimeout = null;
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
    _signalSub?.cancel();
    _signalSub = null;
    _dcStateSub?.cancel();
    _dcStateSub = null;
    _dcMsgSub?.cancel();
    _dcMsgSub = null;
    try { _dc?.close(); } catch (_) {}
    _dc = null;
    try { _pc?.close(); } catch (_) {}
    _pc = null;
    try { _signal?.sink.close(); } catch (_) {}
    _signal = null;
    if (!_messageController.isClosed) await _messageController.close();
    if (!_stateController.isClosed) await _stateController.close();
    if (!_stepController.isClosed) await _stepController.close();
  }

  // ---- diagnostic helpers ----

  int _since(DateTime t) => DateTime.now().difference(t).inMilliseconds;
  String _fmt(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}.${t.millisecond.toString().padLeft(3, '0')}';
}
