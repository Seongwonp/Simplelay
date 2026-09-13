import 'package:flutter/material.dart';

import '../../theme/kiosk_colors.dart';

/// 방해 금지 — 사용 습관 제안을 잠시 멈춘다.
///
/// 선택지가 46px, '취소'는 13px 글자 하나라 고령 사용자 기준 터치 크기(48px)에
/// 못 미쳤고, 스크린리더에는 버튼으로 읽히지도 않았다. 모든 선택지를 실제
/// 버튼으로, 최소 48px로 둔다.
class DndOverlay extends StatelessWidget {
  const DndOverlay({
    super.key,
    required this.dndUntil,
    required this.onSet,
    required this.onClear,
    required this.onDismiss,
  });

  final DateTime? dndUntil;
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
                      '방해 금지',
                      style: TextStyle(
                        fontSize: 24,
                        color: Color(0xFFFAF7F2),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      dndUntil != null
                          ? '사용 습관 제안이 일시 중단됨'
                          : '사용 습관 제안을 잠시 멈춥니다',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 18,
                        color: KioskColors.muted,
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (dndUntil == null) ...[
                      _DndOption(label: '30분', onTap: () => onSet(30)),
                      const SizedBox(height: 8),
                      _DndOption(label: '1시간', onTap: () => onSet(60)),
                      const SizedBox(height: 8),
                      _DndOption(label: '2시간', onTap: () => onSet(120)),
                    ] else ...[
                      _DndOption(
                        label: '방해 금지 해제',
                        accent: true,
                        onTap: onClear,
                      ),
                    ],
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: onDismiss,
                      style: TextButton.styleFrom(
                        foregroundColor: KioskColors.muted,
                        minimumSize: const Size(120, 48),
                      ),
                      child: const Text('취소', style: TextStyle(fontSize: 18)),
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
        child: Text(
          label,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
