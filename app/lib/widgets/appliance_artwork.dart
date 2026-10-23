import 'package:appliance_artwork/appliance_artwork.dart';
import 'package:flutter/material.dart';
import '../models/appliance.dart';
import '../theme/app_colors.dart';

/// 종류를 알아보는 장식용 그림. 실제 기기 사진이나 전원/준비 판정이 아니다.
///
/// 그림 자체는 키오스크와 함께 쓰는 `packages/appliance_artwork`에 있다(2026-10-24 — 두 화면이 같은 그림).
class ApplianceArtwork extends StatelessWidget {
  const ApplianceArtwork(
      {required this.category, this.size = 64, this.color, super.key});
  final ApplianceCategory category;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: SizedBox(
          key: Key('appliance-artwork-${category.value}'),
          width: size,
          height: size,
          child: category == ApplianceCategory.other
              ? Icon(category.icon,
                  size: size * .65, color: color ?? context.appInk)
              : CustomPaint(
                  painter: AppliancePainter(category.value, color ?? context.appInk,
                      Theme.of(context).colorScheme.surfaceContainerLow)),
        ),
      );
}
