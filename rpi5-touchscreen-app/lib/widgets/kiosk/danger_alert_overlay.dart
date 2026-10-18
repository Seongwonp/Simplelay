import 'package:flutter/material.dart';

import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'kiosk_scroll_area.dart';

/// RPi4가 UART로 즉시 밀어주는 alert(승인 절차 없음, docs/protocol.md) — 어느
/// 화면이 떠 있든 최상단에 덮어써서 지금 뭘 하고 있었는지와 무관하게 즉시
/// 알아차리게 한다.
///
/// "확인"은 이 화면(클라이언트)에서만 숨기는 것 — RPi4의 실제 감지 상태는
/// 그대로 유지된다(오탐이었을 수도 있으니 강제로 안 없앰). 계속 울리는
/// 상태라면 alert_cleared가 오기 전까지는 그냥 둬도 자동으로는 안 없어진다 —
/// 새로 한 번 더 raised로 바뀌면(edge) kiosk_screen.dart가 다시 띄운다.
/// 경보 화면의 큰 한 줄(결선 모의 평가 10/18).
const kDanger119 = '위급하면 119에 전화하세요';

class DangerAlertOverlay extends StatelessWidget {
  const DangerAlertOverlay({super.key, required this.onAcknowledge});

  final VoidCallback onAcknowledge;

  @override
  Widget build(BuildContext context) {
    // 스크린리더가 떠오르는 즉시 읽게 한다. 눈으로 화면을 보지 않는 사용자에게
    // 음성 경보(TTS)와 함께 이것이 유일한 알림 채널이다.
    return Semantics(
      liveRegion: true,
      container: true,
      child: ColoredBox(
        color: const Color(0xFF200A09),
        child: KioskScrollArea(
          center: true,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.warning_rounded,
                size: 64,
                color: KioskColors.danger,
              ),
              const SizedBox(height: 24),
              const Text(
                '경보 소리가 들려요',
                style: TextStyle(
                  fontSize: KioskType.status,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                '불이 났는지, 가스가 새는지 살펴 주세요',
                style: TextStyle(fontSize: KioskType.body, color: Colors.white),
              ),
              const SizedBox(height: 4),
              const Text(
                '연기나 냄새가 나면 먼저 밖으로 나가 도움을 요청하세요',
                // 안전이 먼저다 — 이전 문구("실제 상황인지 직접 확인해주세요")는
                // 화재·가스 상황에서 고령 사용자를 위험 쪽으로 보낼 수 있었다.
                style: TextStyle(fontSize: KioskType.body, color: Colors.white),
              ),
              const SizedBox(height: 14),
              // 누구에게 도움을 요청하는지 한 줄 크게(결선 모의 평가 10/18 — '도움을 요청하세요'만 있었다).
              // 가족 휴대폰에 알렸다고는 쓰지 않는다: 서버는 위험 신호음을 보호자 알림함(care events)에 기록만 하고,
              // 폰은 앱이 켜져 있을 때 45초마다 당겨 온다(푸시 없음). 이 화면은 기록이 됐는지도 받지 않는다.
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.call, size: KioskType.status + 4, color: KioskColors.danger),
                  const SizedBox(width: KioskSpace.sm),
                  const Flexible(
                    child: Text(
                      kDanger119,
                      key: ValueKey('danger-119'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: KioskType.status,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const Text(
                '경보가 아닌 다른 소리일 수도 있어요',
                style:
                    TextStyle(fontSize: KioskType.caption, color: Colors.white),
              ),
              const SizedBox(height: 32),
              SizedBox(
                // 큰 글씨 모드(1.22배)에서도 문구가 잘리지 않는 폭
                width: 320,
                height: KioskSizes.primaryButton,
                child: FilledButton(
                  onPressed: onAcknowledge,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: KioskColors.stop,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text(
                    '안내를 확인했어요',
                    style: TextStyle(
                        fontSize: KioskType.body, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
