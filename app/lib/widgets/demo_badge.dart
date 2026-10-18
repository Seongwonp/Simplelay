import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

/// 이 가전은 **연습**(데모 표본·서버 연습 기기)이라고 말하는 작은 표시.
///
/// 표본을 진짜 등록된 가전처럼 보여주면, 우리가 실제로 만든 것과 보여주기
/// 위해 세운 것을 아무도 구분할 수 없다.
///
/// 휴리스틱 평가(10/18): 연습 가전이 실제 가전과 같은 회색이었다 → 글자·테두리를 연습 색(청록, [AppColorsX.appPractice]).
class DemoBadge extends StatelessWidget {
  const DemoBadge({super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: AppSpace.xs),
        decoration: BoxDecoration(
          color: context.appPractice.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: context.appPractice.withValues(alpha: 0.6)),
        ),
        child: Text(
          '연습',
          style: TextStyle(
            fontSize: AppFont.caption,
            fontWeight: FontWeight.w700,
            color: context.appPractice,
          ),
        ),
      );
}
