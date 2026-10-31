import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

enum QrCameraProblem { permissionDenied, unavailable }

typedef QrCameraViewBuilder = Widget Function({
  required ValueChanged<String> onCode,
  required ValueChanged<QrCameraProblem> onProblem,
});

/// 시험은 실제 카메라 없이 값을 넣을 수 있게 이 경계를 바꾼다.
final qrCameraViewProvider = Provider<QrCameraViewBuilder>(
    (_) => ({required onCode, required onProblem}) =>
        _MobileScannerView(onCode: onCode, onProblem: onProblem));

class _MobileScannerView extends StatefulWidget {
  const _MobileScannerView({required this.onCode, required this.onProblem});
  final ValueChanged<String> onCode;
  final ValueChanged<QrCameraProblem> onProblem;

  @override
  State<_MobileScannerView> createState() => _MobileScannerViewState();
}

class _MobileScannerViewState extends State<_MobileScannerView> {
  bool _reported = false;

  // errorBuilder는 그리는 중에 불리므로 화면 이동은 그 뒤로 미룬다. 다시 그려져도 한 번만 알린다.
  void _report(MobileScannerException error) {
    if (_reported) return;
    _reported = true;
    final problem = error.errorCode == MobileScannerErrorCode.permissionDenied
        ? QrCameraProblem.permissionDenied
        : QrCameraProblem.unavailable;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onProblem(problem);
    });
  }

  // 컨트롤러를 넘기지 않아야 앱이 뒤로 갔다 올 때 패키지가 카메라를 멈추고 다시 켠다.
  @override
  Widget build(BuildContext context) => MobileScanner(
        onDetect: (capture) {
          for (final barcode in capture.barcodes) {
            final value = barcode.rawValue;
            if (barcode.format == BarcodeFormat.qrCode && value != null) {
              widget.onCode(value);
            }
          }
        },
        errorBuilder: (_, error) {
          _report(error);
          return const ColoredBox(color: Colors.black);
        },
      );
}
