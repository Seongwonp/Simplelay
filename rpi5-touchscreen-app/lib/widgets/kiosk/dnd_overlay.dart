import 'package:flutter/material.dart';

import '../../theme/kiosk_colors.dart';

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
              width: 300,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
              decoration: BoxDecoration(
                color: KioskColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: KioskColors.border),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '방해 금지',
                    style: TextStyle(
                      fontSize: 17,
                      color: Color(0xFFFAF7F2),
                      fontWeight: FontWeight.w300,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    dndUntil != null
                        ? 'AI 제안이 일시 중단됨'
                        : 'AI 제안을 잠시 멈춥니다',
                    style: const TextStyle(
                      fontSize: 14,
                      color: KioskColors.muted,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                  const SizedBox(height: 28),
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
                  const SizedBox(height: 18),
                  GestureDetector(
                    onTap: onDismiss,
                    child: const Text(
                      '취소',
                      style: TextStyle(fontSize: 13, color: KioskColors.muted),
                    ),
                  ),
                ],
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        height: 46,
        decoration: BoxDecoration(
          color: accent
              ? KioskColors.warning.withValues(alpha: 0.12)
              : KioskColors.surface2,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: accent
                ? KioskColors.warning.withValues(alpha: 0.35)
                : KioskColors.border,
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: accent ? KioskColors.warning : const Color(0xFFFAF7F2),
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}
