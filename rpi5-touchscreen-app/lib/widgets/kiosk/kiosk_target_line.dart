import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'kiosk_text.dart';

/// "어느 가전에 대한 이야기인가"를 한 줄로.
///
/// 제안·실행·완료가 같은 모양으로 말한다. 여러 가전을 다루는 키오스크에서
/// 엉뚱한 가전에 대고 맡긴 뒤에 알면 늦다. 대상을 모르면 이 줄을 그리지
/// 않는다 -- 지금 고른 가전으로 메우지 않는다.
class KioskTargetLine extends StatelessWidget {
  const KioskTargetLine(
      {super.key, required this.appliance, this.size = KioskType.body, this.detail, this.textKey});

  final ApplianceMap appliance;
  final double size;

  /// 가전 이름 뒤에 ' · '로 붙일 말(실패 화면의 행동 이름 '즉석밥 데우기', 평가 5차 10/18). 없으면 가전 이름만.
  final String? detail;
  final Key? textKey;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(appliance.icon, size: size + 4, color: KioskColors.muted),
          const SizedBox(width: 10),
          Flexible(
            child: detail == null || detail!.isEmpty
                ? Text(
                    appliance.displayName,
                    key: textKey,
                    style: TextStyle(fontSize: size, color: KioskColors.muted),
                    overflow: TextOverflow.ellipsis,
                  )
                // 행동 이름까지 붙이면 길어진다 — 말줄임 대신 어절 단위로 줄을 바꾼다.
                : KioskText('${appliance.displayName} · $detail',
                    textKey: textKey,
                    style: TextStyle(fontSize: size, color: KioskColors.ink)),
          ),
        ],
      );
}
