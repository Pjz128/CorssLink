import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../models/pairing.dart';
import '../services/crypto_service.dart';
import '../services/http_service.dart';
import '../services/pairing_service.dart';
import '../theme/crosslink_theme.dart';

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
      backgroundColor: CrossLinkTheme.bg,
      appBar: AppBar(
        title: const Text('扫码配对'),
        backgroundColor: CrossLinkTheme.bg.withAlpha(200),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: controller,
            onDetect: _detected ? null : _onDetect,
          ),
          // 暗角遮罩
          Container(
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(120),
            ),
            child: Center(
              child: SizedBox(
                width: 250,
                height: 250,
                child: SvgPicture.asset(
                  'assets/brand/scan_frame.svg',
                  width: 250,
                  height: 250,
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 80,
            left: 0,
            right: 0,
            child: Text(
              '将相机对准电脑端 CrossLink Agent 的二维码',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white.withAlpha(200),
                    shadows: [
                      const Shadow(color: Colors.black, blurRadius: 8),
                    ],
                  ),
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
        _showPairingSheet(qr);
        return;
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无效的二维码：$e')),
        );
      }
    }
  }

  void _showPairingSheet(QRPayload qr) {
    showModalBottomSheet(
      context: context,
      isDismissible: false,
      isScrollControlled: true,
      backgroundColor: CrossLinkTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(CrossLinkTheme.rLg)),
      ),
      builder: (ctx) => _PairingSheet(qr: qr),
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

class _PairingSheet extends StatefulWidget {
  final QRPayload qr;

  const _PairingSheet({required this.qr});

  @override
  State<_PairingSheet> createState() => _PairingSheetState();
}

class _PairingSheetState extends State<_PairingSheet> {
  String _status = '正在初始化加密…';
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
      setState(() => _status = '正在连接 Agent…');
      try {
        final baseUrl = qr.serverUrl.split('/pair?').first;
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

    final token = await _pairing.pair(
      qr,
      deviceName,
      onStatus: (status, detail) {
        if (!mounted) return;
        setState(() {
          switch (status) {
            case PairingStatus.connecting:
              _status = '正在连接信令服务器…';
            case PairingStatus.requestSent:
              _status = '正在发送配对请求…';
            case PairingStatus.accepted:
              _status = '配对成功！\n正在解密密钥…';
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
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(CrossLinkTheme.sXxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _done
                  ? CrossLinkTheme.success.withAlpha(40)
                  : _failed
                      ? CrossLinkTheme.error.withAlpha(40)
                      : CrossLinkTheme.accent.withAlpha(40),
            ),
            child: Center(
              child: _done
                  ? const Icon(Icons.check_circle, color: CrossLinkTheme.success, size: 28)
                  : _failed
                      ? const Icon(Icons.error_outline, color: CrossLinkTheme.error, size: 28)
                      : const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
            ),
          ),
          const SizedBox(height: CrossLinkTheme.sLg),
          Text(
            _done ? '配对成功' : _failed ? '配对失败' : '正在配对…',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: CrossLinkTheme.sSm),
          Text(
            _status,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: CrossLinkTheme.sXs),
          Text(
            'Agent: ${widget.qr.peerId}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurface.withAlpha(120),
                ),
          ),
          if (_result != null) ...[
            const SizedBox(height: CrossLinkTheme.sSm),
            Text(
              '密钥：${_result!.token.substring(0, 16)}…',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurface.withAlpha(120),
                    fontFamily: 'monospace',
                  ),
            ),
          ],
          const SizedBox(height: CrossLinkTheme.sXl),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(_done ? '关闭' : '取消'),
                ),
              ),
              if (_done && _result != null) ...[
                const SizedBox(width: CrossLinkTheme.sMd),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, _result),
                    child: const Text('保存设备'),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
