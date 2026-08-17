import 'package:flutter/material.dart';

import '../../theme/kiosk_colors.dart';

/// RPi4가 UART로 즉시 밀어주는 alert(승인 절차 없음, docs/protocol.md) — 어느
/// 화면이 떠 있든 최상단에 덮어써서 지금 뭘 하고 있었는지와 무관하게 즉시
/// 알아차리게 한다.
///
/// "확인"은 이 화면(클라이언트)에서만 숨기는 것 — RPi4의 실제 감지 상태는
/// 그대로 유지된다(오탐이었을 수도 있으니 강제로 안 없앰). 계속 울리는
/// 상태라면 alert_cleared가 오기 전까지는 그냥 둬도 자동으로는 안 없어진다 —
/// 새로 한 번 더 raised로 바뀌면(edge) kiosk_screen.dart가 다시 띄운다.
class DangerAlertOverlay extends StatelessWidget {
  const DangerAlertOverlay({super.key, required this.onAcknowledge});

  final VoidCallback onAcknowledge;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF200A09),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.warning_rounded,
              size: 88,
              color: KioskColors.danger,
            ),
            const SizedBox(height: 24),
            const Text(
              '위험 신호음 감지',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '화재·가스 경보음으로 추정되는 소리가 감지되었습니다',
              style: TextStyle(fontSize: 15, color: Color(0xFFE8B4B1)),
            ),
            const SizedBox(height: 4),
            const Text(
              '오탐일 수도 있습니다 — 실제 상황인지 직접 확인해주세요',
              style: TextStyle(fontSize: 12, color: KioskColors.muted),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: 200,
              height: 52,
              child: OutlinedButton(
                onPressed: onAcknowledge,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white38),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text(
                  '확인',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
