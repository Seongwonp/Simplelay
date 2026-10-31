import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/pairing_qr.dart';
import '../theme/app_tokens.dart';
import '../widgets/qr_camera_view.dart';

/// 스캔 결과. 그냥 뒤로 가면 결과 없이(null) 닫힌다.
class QrScanResult {
  const QrScanResult.scanned(PairingQr this.qr) : problem = null;
  const QrScanResult.failed(QrCameraProblem this.problem) : qr = null;
  final PairingQr? qr;
  final QrCameraProblem? problem;
}

/// 앱 안에서 본체 QR을 찍는 전체 화면.
class PairingQrScanScreen extends ConsumerStatefulWidget {
  const PairingQrScanScreen({super.key});

  @override
  ConsumerState<PairingQrScanScreen> createState() =>
      _PairingQrScanScreenState();
}

class _PairingQrScanScreenState extends ConsumerState<PairingQrScanScreen> {
  String _message = '본체 화면의 QR이 잘 보이게 비춰 주세요.';

  /// 닫히는 동안에도 카메라가 값을 보낼 수 있다 — 연결 요청은 한 번만 나가야 한다.
  bool _finished = false;

  void _finish(QrScanResult result) {
    if (_finished) return;
    _finished = true;
    Navigator.of(context).pop(result);
  }

  void _onCode(String raw) {
    if (_finished) return;
    final qr = PairingQr.tryParse(raw);
    if (qr != null) {
      _finish(QrScanResult.scanned(qr));
    } else if (_message != kNotPairingQrMessage) {
      setState(() => _message = kNotPairingQrMessage);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cameraView = ref.watch(qrCameraViewProvider);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('본체 QR 찍기'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Stack(fit: StackFit.expand, children: [
        cameraView(
          onCode: _onCode,
          onProblem: (problem) => _finish(QrScanResult.failed(problem)),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.all(AppSpace.lg),
              padding: const EdgeInsets.all(AppSpace.lg),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _message,
                  key: const Key('pair-scan-message'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: AppFont.body),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
