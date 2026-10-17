import 'package:flutter/material.dart';

import '../models/routine.dart';
import '../theme/app_icons.dart';

/// 루틴 아이콘 = 대상 가전 아이콘(평가 3차 10/18 — 모든 루틴이 같은 목록 아이콘이라 줄을 가를 수 없었다).
///
/// 가전이 둘 이상이면 첫 가전 아이콘에 둘째 가전 아이콘을 작게 겹친다. 대상 가전을 모르면(알림만 루틴·지운 가전)
/// 루틴 아이콘. 아이콘은 꾸밈이다 — 루틴 이름·부제가 무엇을 하는지 말하므로 낭독에서는 뺀다.
class RoutineIcon extends StatelessWidget {
  const RoutineIcon({
    super.key,
    required this.routine,
    required this.iconOf,
    required this.color,
    this.size = 24,
  });

  final Routine routine;

  /// 가전 id → 아이콘. 모르는 가전은 빠진다.
  final Map<String, IconData> iconOf;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final icons = [
      for (final id in routine.applianceIds)
        if (iconOf[id] case final icon?) icon,
    ];
    if (icons.isEmpty) {
      return ExcludeSemantics(child: Icon(AppIcons.routine, size: size, color: color));
    }
    final main = Icon(icons.first, size: size, color: color);
    if (icons.length == 1) return ExcludeSemantics(child: main);
    final small = size * 0.6;
    final surface = Theme.of(context).cardTheme.color ?? Theme.of(context).colorScheme.surface;
    return ExcludeSemantics(
      child: SizedBox(
        width: size + small / 2,
        height: size + small / 3,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(left: 0, top: 0, child: main),
            Positioned(
              key: const Key('routine-icon-more'),
              right: 0,
              bottom: 0,
              child: Container(
                // 바탕색 테두리로 첫 아이콘과 갈라 겹쳐 보이게 한다.
                decoration: BoxDecoration(
                  color: surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: surface, width: 1.5),
                ),
                child: Icon(icons[1], size: small, color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
