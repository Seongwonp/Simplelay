import 'package:flutter/material.dart';

import '../../theme/kiosk_colors.dart';

/// 연습(모의) 실행 표시 — 화면 맨 위에 고정한 띠(2026-10-15 문구 개선 §3-2).
///
/// 작은 칩('연습 모드')은 처음 보는 사람이 놓쳤다. 띠는 스크롤 밖에 두고, 큰 글씨에서도
/// 글자를 줄이지 않는다(넘치면 줄을 바꾼다).
const kPracticeBandText = '연습 중 · 실제 가전은 누르지 않아요';

class KioskPracticeBand extends StatelessWidget {
  const KioskPracticeBand({super.key});

  @override
  Widget build(BuildContext context) => Container(
        key: const ValueKey('practice-band'),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: KioskColors.warning.withValues(alpha: 0.16),
          border: const Border(
              bottom: BorderSide(color: KioskColors.warning, width: 2)),
        ),
        child: const Row(
          children: [
            Icon(Icons.school_outlined, size: 22, color: KioskColors.warning),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                kPracticeBandText,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: KioskColors.warning,
                ),
              ),
            ),
          ],
        ),
      );
}
