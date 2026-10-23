import 'package:flutter/material.dart';

import '../../theme/kiosk_tokens.dart';

import '../../theme/kiosk_colors.dart';

/// 화면 머리의 뒤로 단추 — 흰 화살표 + '뒤로' 글자 + 테두리(UI 평가 4차 2026-10-17).
///
/// 회색 가는 화살표만 있으면 1~2 m에서 잘 안 보였다. 평소 화면 위쪽 아이콘에 이름을 붙인 것과 같은 기준이다.
/// 누르는 자리는 높이 52·너비 88 이상. 읽는 이름은 [semanticLabel](어디로 돌아가는지).
class KioskBackButton extends StatelessWidget {
  const KioskBackButton({
    super.key = const ValueKey('kiosk-back'),
    required this.onTap,
    this.semanticLabel = '대기 화면으로 돌아가기',
  });

  final VoidCallback onTap;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: semanticLabel,
        excludeSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              constraints: const BoxConstraints(minWidth: 88, minHeight: 52),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: KioskColors.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.arrow_back, color: KioskColors.ink, size: 26),
                  SizedBox(width: 6),
                  Text('뒤로',
                      style: TextStyle(fontSize: KioskType.body, fontWeight: FontWeight.w600, color: KioskColors.ink)),
                ],
              ),
            ),
          ),
        ),
      );
}
