import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

/// 이 가전은 데모 세션이 세운 **표본**이라고 말하는 작은 표시.
///
/// 표본을 진짜 등록된 가전처럼 보여주면, 우리가 실제로 만든 것과 보여주기
/// 위해 세운 것을 아무도 구분할 수 없다.
class DemoBadge extends StatelessWidget {
  const DemoBadge({super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: AppSpace.xs),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: context.appBorderSubtle, width: 0.5),
        ),
        child: Text(
          '연습',
          style: TextStyle(
            fontSize: AppFont.caption,
            fontWeight: FontWeight.w600,
            color: context.appMuted,
          ),
        ),
      );
}
