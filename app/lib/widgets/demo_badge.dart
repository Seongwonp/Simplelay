import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

/// 데모 표본과 서버 연습 기기를 실제 등록 가전과 구분하는 표시.
/// 글자와 테두리에 [AppColorsX.appPractice]를 사용한다.
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
