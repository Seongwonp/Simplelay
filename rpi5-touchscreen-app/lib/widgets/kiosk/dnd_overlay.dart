import 'package:flutter/material.dart';

import '../../theme/kiosk_tokens.dart';

import '../../models/kiosk_time.dart';
import 'kiosk_text.dart';
import '../../theme/kiosk_colors.dart';

/// 제안 잠시 쉬기(예전 이름 '방해 금지', 2026-10-15) — 새 제안과 아직 시작하지 않은 자동 실행을 잠시 쉰다.
/// 이름만 보면 제안만 쉬는 줄 알아서, 쉬는 범위를 늘 바로 아래에 적는다.
///
/// 선택지가 46px, '취소'는 13px 글자 하나라 고령 사용자 기준 터치 크기(48px)에
/// 못 미쳤고, 스크린리더에는 버튼으로 읽히지도 않았다. 모든 선택지를 실제
/// 버튼으로, 최소 48px로 둔다.
class DndOverlay extends StatelessWidget {
  const DndOverlay({
    super.key,
    required this.dndUntil,
    this.dndScope,
    this.quietSchedule,
    required this.onSet,
    required this.onClear,
    required this.onDismiss,
  });

  final DateTime? dndUntil;

  /// 잠시 쉬기 범위(서버 `dnd_scope`) — `suggestions_only`(업데이트 전 설정을 이어받음)면 새 제안만 쉰다고 말한다.
  final String? dndScope;

  /// 켜 둔 매일 조용한 시간대 (시작, 끝) — 보여 주기만 한다(바꾸기는 폰 설정, 2026-10-14).
  final (String, String)? quietSchedule;
  final void Function(int minutes) onSet;
  final VoidCallback onClear;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onDismiss,
      child: ColoredBox(
        color: const Color(0xCC0C0E12),
        child: Center(
          child: GestureDetector(
            onTap: () {}, // 카드 탭이 배경으로 전파되지 않게 흡수
            child: Container(
              width: 360,
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 12),
              decoration: BoxDecoration(
                color: KioskColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: KioskColors.border),
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '잠시 쉬기',
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: KioskType.body,
                        color: Color(0xFFFAF7F2),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    // 실제 범위만 말한다(2026-10-14) — 새 제안과 아직 시작하지 않은 자동 실행. 직접 실행·정지·경보는 그대로.
                    // 어절 단위로 줄을 바꾼다 — 실패널에서 '쉬어|요'처럼 한 글자가 떨어졌다(평가 4차 10/18).
                    KioskText(
                      // 켜져 있으면 끝나는 시각을 함께 적는다(2026-10-14 마감 확인 A5) — 위 줄 칩은 남은 시간.
                      // 자동 계열 이름은 '자동으로 해요' 하나로(평가 4차 10/18) — 문장 안에서는 '자동으로 하는 일'.
                      dndUntil == null
                          ? '새 제안과 자동으로 하는 일을 잠시 쉬어요'
                          : dndScope == 'suggestions_only'
                              ? '${_clockOf(dndUntil!)}까지 새 제안만 쉬어요. 자동으로 하는 일은 그대로예요'
                              : '${_clockOf(dndUntil!)}까지 새 제안과 자동으로 하는 일을 쉬어요',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: KioskType.caption,
                        color: KioskColors.muted,
                      ),
                    ),
                    if (quietSchedule case (final start, final end)) ...[
                      const SizedBox(height: 6),
                      KioskText(
                        '매일 ${spokenHhmm(start)}부터 ${spokenHhmm(end)}까지 조용한 시간이에요. 폰 설정에서 바꿔요',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: KioskType.caption, color: KioskColors.muted),
                      ),
                    ],
                    const SizedBox(height: 20),
                    if (dndUntil == null) ...[
                      _DndOption(label: '30분', onTap: () => onSet(30)),
                      const SizedBox(height: 8),
                      _DndOption(label: '1시간', onTap: () => onSet(60)),
                      const SizedBox(height: 8),
                      _DndOption(label: '2시간', onTap: () => onSet(120)),
                    ] else ...[
                      _DndOption(
                        label: '쉬기 끝내기',
                        accent: true,
                        onTap: onClear,
                      ),
                    ],
                    const SizedBox(height: 8),
                    // 테두리 버튼 — 글자만 있으면 누를 곳으로 보이지 않는다(UI 평가 10/17).
                    OutlinedButton(
                      onPressed: onDismiss,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: KioskColors.border, width: 2),
                        minimumSize: const Size(160, 52),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('취소', style: TextStyle(fontSize: KioskType.caption)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DndOption extends StatelessWidget {
  const _DndOption({
    required this.label,
    required this.onTap,
    this.accent = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 56),
          backgroundColor: accent
              ? KioskColors.warning.withValues(alpha: 0.12)
              : KioskColors.surface2,
          foregroundColor: accent ? KioskColors.warning : const Color(0xFFFAF7F2),
          side: BorderSide(
            color: accent
                ? KioskColors.warning.withValues(alpha: 0.35)
                : KioskColors.border,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: KioskText(
          label,
          style: const TextStyle(fontSize: KioskType.body, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// 잠시 쉬기가 끝나는 시각 '오전 8시 38분'(키오스크 현지 시각, 오전/오후로 통일 — 평가 4차 10/18).
String _clockOf(DateTime until) {
  final t = until.toLocal();
  return spokenTime(t.hour, t.minute);
}
