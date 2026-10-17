import 'package:flutter/material.dart';

import '../../theme/kiosk_colors.dart';
import 'kiosk_phase.dart';

class TopProgressBar extends StatelessWidget {
  const TopProgressBar({super.key, required this.phase, required this.execBarValue});

  final KioskPhase phase;
  final double execBarValue;

  @override
  Widget build(BuildContext context) {
    // 진행 막대는 실행·결과에서만 — 평소·제안 화면에서는 빈 회색 줄이 무엇인지 몰랐다(평가 5차 10/18, 실패널 k01).
    if (phase != KioskPhase.executing && phase != KioskPhase.done) return const SizedBox.shrink();
    final value = switch (phase) {
      KioskPhase.executing => execBarValue * 0.8,
      KioskPhase.done => 1.0,
      _ => 0.0,
    };
    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        children: [
          Container(color: KioskColors.surface),
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: constraints.maxWidth * value.clamp(0.0, 1.0),
            decoration: BoxDecoration(
              color: KioskColors.primary,
              boxShadow: [
                BoxShadow(
                  color: KioskColors.primary.withValues(alpha: 0.6),
                  blurRadius: 6,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
