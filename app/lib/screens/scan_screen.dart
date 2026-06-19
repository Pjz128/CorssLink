import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../models/pairing.dart';
import '../services/crypto_service.dart';
import '../services/http_service.dart';
import '../services/pairing_service.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  MobileScannerController controller = MobileScannerController();
  bool _detected = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('扫码配对'),
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: controller,
            onDetect: _detected ? null : _onDetect,
          ),
          // Scan overlay frame
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.green, width: 2),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          // Hint text
          Positioned(
            bottom: 80,
            left: 0,
            right: 0,
            child: Text(
              '将相机对准电脑端 CrossLink Agent 的二维码',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }

  void _onDetect(BarcodeCapture capture) {
    if (_detected) return;

    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null || !value.startsWith('crosslink://pair?')) continue;

      try {
        setState(() => _detected = true);
        final qr = QRPayload.fromUri(value);
        _showPairingDialog(qr);
        return;
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无效的二维码：$e')),
        );
      }
    }
  }

  void _showPairingDialog(QRPayload qr) {
    showDialog<PairedDevice>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _PairingDialog(qr: qr),
    ).then((device) {
      if (device != null && mounted) {
        Navigator.pop(context, device);
      } else {
        setState(() => _detected = false);
      }
    });
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}

/// Dialog that drives the real pairing handshake.
class _PairingDialog extends StatefulWidget {
  final QRPayload qr;
  const _PairingDialog({required this.qr});

  @override
  State<_PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<_PairingDialog> {
  String _status = '正在初始化加密...';
  bool _done = false;
  bool _failed = false;
  PairedDevice? _result;
  late final PairingService _pairing;

  @override
  void initState() {
    super.initState();
    final crypto = CryptoService();
    final deviceId = 'flutter-${DateTime.now().millisecondsSinceEpoch}';
    _pairing = PairingService(crypto: crypto, deviceId: deviceId);
    _startPairing();
  }

  Future<void> _startPairing() async {
    final qr = widget.qr;
    const deviceName = 'Flutter Device';

    if (qr.isHttpV2) {
      // ---- HTTP v2 pairing (simplified, no WebSocket) ----
      setState(() => _status = '正在连接 Agent...');
      try {
        final baseUrl = qr.serverUrl.split('/pair?').first; // extract base
        final device = await HttpPairing.pair(
          serverUrl: baseUrl,
          pairToken: qr.pairToken,
          deviceName: deviceName,
        );
        if (!mounted) return;
        setState(() {
          _result = device;
          _status = '已连接到 ${qr.peerId}';
          _done = true;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _status = '配对失败：$e';
          _failed = true;
        });
      }
      return;
    }

    // ---- WebSocket v1 pairing (fallback) ----
    final token = await _pairing.pair(
      qr,
      deviceName,
      onStatus: (status, detail) {
        if (!mounted) return;
        setState(() {
          switch (status) {
            case PairingStatus.connecting:
              _status = '正在连接信令服务器...';
            case PairingStatus.requestSent:
              _status = '正在发送配对请求...';
            case PairingStatus.accepted:
              _status = '配对成功！\n正在解密密钥...';
            case PairingStatus.rejected:
              _status = '配对被拒绝\n请在电脑端确认配对请求';
              _failed = true;
            case PairingStatus.timeout:
              _status = '配对超时\n请确认电脑端 Agent 在线且二维码未过期';
              _failed = true;
            case PairingStatus.error:
              _status = '错误：$detail';
              _failed = true;
          }
        });
      },
    );

    if (!mounted) return;

    if (token != null) {
      setState(() {
        _result = token.toPairedDevice();
        _status = '已连接到 ${token.agentId}';
        _done = true;
      });
    } else if (!_failed) {
      setState(() {
        _status = '配对失败，请重试';
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_done ? '配对成功！' : _failed ? '配对失败' : '正在配对...'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_done && !_failed)
            const Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ),
          if (_failed)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.error_outline, color: Colors.red, size: 40),
            ),
          if (_done)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.check_circle, color: Colors.green, size: 40),
            ),
          Text(_status, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 8),
          Text(
            'Agent: ${widget.qr.peerId}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_result != null) ...[
            const SizedBox(height: 8),
            Text(
              '密钥：${_result!.token.substring(0, 16)}...',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_done ? '关闭' : '取消'),
        ),
        if (_done && _result != null)
          FilledButton(
            onPressed: () => Navigator.pop(context, _result),
            child: const Text('保存设备'),
          ),
      ],
    );
  }
}
