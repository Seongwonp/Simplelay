import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 제어 경로 배지(물리 버튼 / ThinQ). 색이 아니라 글자로 말한다.
///
/// 시나리오 카드·가전 목록·단계별 결과가 같은 모양을 쓴다 -- 같은 사실을
/// 자리마다 다른 모양으로 말하면 같은 뜻으로 읽히지 않는다.
class RouteBadge extends StatelessWidget {
  const RouteBadge({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: context.appBorderSubtle),
        ),
        child: Text(label, style: const TextStyle(fontSize: 14)),
      );
}
