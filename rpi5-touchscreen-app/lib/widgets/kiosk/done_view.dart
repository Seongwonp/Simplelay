import 'package:flutter/material.dart';

import '../../theme/kiosk_colors.dart';

const Duration _kDoneReturnDuration = Duration(seconds: 3);

class KioskDoneView extends StatelessWidget {
  const KioskDoneView({
    super.key,
    required this.success,
    required this.label,
  });

  final bool success;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = success ? KioskColors.success : KioskColors.danger;
    return ColoredBox(
      color: KioskColors.bg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 이중 링 아이콘
            Container(
              width: 144,
              height: 144,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.05),
                border: Border.all(
                  color: color.withValues(alpha: 0.15),
                  width: 1,
                ),
              ),
              child: Center(
                child: Container(
                  width: 116,
                  height: 116,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withValues(alpha: 0.14),
                    border:
                        Border.all(color: color.withValues(alpha: 0.45), width: 2),
                  ),
                  child: Icon(
                    success ? Icons.check : Icons.close,
                    size: 54,
                    color: color,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              success ? '완료' : '실패',
              style: TextStyle(
                fontSize: 38,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              success
                  ? '$label — 모든 버튼 동작 확인됨'
                  : '$label — 실행 중 문제가 발생했습니다',
              style: const TextStyle(fontSize: 16, color: KioskColors.muted),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: 200,
              height: 4,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 1.0, end: 0.0),
                duration: _kDoneReturnDuration,
                builder: (context, value, _) => ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: value,
                    minHeight: 4,
                    backgroundColor: KioskColors.border,
                    valueColor:
                        AlwaysStoppedAnimation(Colors.white.withValues(alpha: 0.3)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
