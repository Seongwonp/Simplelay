import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';

/// "어느 가전에 대한 이야기인가"를 한 줄로.
///
/// 제안·실행·완료가 같은 모양으로 말한다. 여러 가전을 다루는 키오스크에서
/// 엉뚱한 가전에 대고 맡긴 뒤에 알면 늦다. 대상을 모르면 이 줄을 그리지
/// 않는다 -- 지금 고른 가전으로 메우지 않는다.
class KioskTargetLine extends StatelessWidget {
  const KioskTargetLine({super.key, required this.appliance, this.size = KioskType.body});

  final ApplianceMap appliance;
  final double size;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(appliance.icon, size: size + 4, color: KioskColors.muted),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              appliance.name,
              style: TextStyle(fontSize: size, color: KioskColors.muted),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
}
