import 'package:flutter/material.dart';

import '../../services/kiosk_api_service.dart';
import '../../theme/kiosk_colors.dart';
import 'kiosk_timings.dart';

class KioskSuggestionView extends StatelessWidget {
  const KioskSuggestionView({
    super.key,
    required this.suggestion,
    required this.cdRemaining,
    required this.onApprove,
    required this.onReject,
  });

  final KioskSuggestion suggestion;
  final int cdRemaining;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'AI 제안',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 2.0,
                color: KioskColors.primary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              suggestion.purpose,
              style: const TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w700,
                height: 1.2,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 14, color: KioskColors.muted),
                children: [
                  const TextSpan(text: '최근 '),
                  TextSpan(
                    text: '${suggestion.occurrences}회',
                    style: const TextStyle(
                      color: KioskColors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const TextSpan(text: ' 같은 시간대에 반복 감지'),
                ],
              ),
            ),
            const SizedBox(height: 40),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: 60,
                    child: ElevatedButton(
                      onPressed: onApprove,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: KioskColors.success,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text(
                        '승인',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 1,
                  child: SizedBox(
                    height: 60,
                    child: OutlinedButton(
                      onPressed: onReject,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: KioskColors.muted,
                        side: const BorderSide(color: KioskColors.border),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text(
                        '거부',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              '$cdRemaining초 후 자동 닫힘',
              // 자동으로 사라진다는 사실은 고령 사용자가 놓치면 안 되는 정보
              style: const TextStyle(fontSize: 14, color: KioskColors.muted),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: cdRemaining / KioskTimings.countdownSeconds,
                minHeight: 2,
                backgroundColor: KioskColors.border,
                valueColor: AlwaysStoppedAnimation(
                  KioskColors.muted.withValues(alpha: 0.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
