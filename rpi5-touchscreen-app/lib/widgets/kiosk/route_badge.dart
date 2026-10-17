import 'package:flutter/material.dart';

import '../../theme/kiosk_tokens.dart';

import '../../theme/kiosk_colors.dart';

/// 제어 경로 배지(물리 버튼 / ThinQ). 색이 아니라 글자로 말한다.
///
/// 시나리오 카드·가전 선택·단계별 결과가 같은 모양을 쓴다.
class KioskRouteBadge extends StatelessWidget {
  const KioskRouteBadge({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: KioskColors.border),
        ),
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          style: const TextStyle(fontSize: KioskType.caption, color: Colors.white),
        ),
      );
}
