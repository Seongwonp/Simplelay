import 'package:flutter/material.dart';

import '../../models/ambient.dart';
import '../../models/appliance.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'appliance_art.dart';
import 'appliance_strip.dart' show KioskTileIssue, KioskTileMark;
import 'kiosk_text.dart';

/// 처음 화면 '무엇을 할까요?' 카드(시안 B 10/24, 폰 홈의 첫 저장 동작 카드와 같은 자리) — 저장된 동작(루틴) 하나.
///
/// **누르면 바로 하지 않는다.** 내 가전 화면의 루틴 칸과 같은 길이다: 서버가 카드를 만들고 그 카드의 '시작'이 승인이다.
/// 저장된 동작이 없거나 그 가전이 목록에 없으면 kiosk_screen·처음 화면이 이 카드를 그리지 않는다(지어내지 않는다).
class KioskFeaturedAction extends StatelessWidget {
  const KioskFeaturedAction({
    super.key,
    required this.routine,
    required this.appliance,
    required this.sizeLabel,
    required this.onRun,
    this.blockedReason,
  });

  final KioskRoutine routine;
  final ApplianceMap appliance;
  final String sizeLabel;
  final VoidCallback onRun;

  /// 지금은 할 수 없는 동작의 이유 한 줄(가전 줄 '!'와 같은 말, [pick]의 셋째 값). 있으면 '실행하기'를 흐리게 그리고, 눌러도
  /// [onRun]을 부르지 않는다(첫 사용 평가 10/24).
  final String? blockedReason;

  /// 머리말 + 카드 높이(처음 화면 오른쪽 칸 높이 재기에 쓴다). 글자 배율이 큰 화면에서는 처음 화면이 이 카드를 두지 않는다.
  static const double cardHeight = 96;
  static const double headGap = KioskSpace.xs;
  static const double headSize = KioskType.body;
  static double heightFor(BuildContext context) {
    final head = MediaQuery.textScalerOf(context).scale(headSize) * 1.25;
    return head + headGap + cardHeight;
  }

  /// 처음 화면에 세울 저장된 동작 — 폰 홈과 같은 후보(켜져 있고, 승인해서 실행하고, 시각 예약이 아닌 루틴) 중
  /// 가전이 목록에 있는 루틴. 없으면 null.
  ///
  /// [issueOf]는 가전 줄 '!'와 같은 판정([kioskTileIssue]). 가전이 모두 지금 쓸 수 있는 루틴을 먼저 고른다. 그런 루틴이
  /// 없으면 첫 후보를 돌려주고 셋째 값에 그 '!' 문장(이유)을 싣는다 — 화면은 '실행하기'를 흐리게 그린다(첫 사용 평가 10/24).
  static (KioskRoutine, ApplianceMap, String?)? pick(List<KioskRoutine>? routines, List<ApplianceMap>? appliances,
      {KioskTileIssue? Function(ApplianceMap a)? issueOf}) {
    if (routines == null || appliances == null) return null;
    (KioskRoutine, ApplianceMap, String?)? firstBlocked;
    for (final r in routines) {
      if (!r.enabled || r.mode != 'approve' || r.timeTriggered) continue;
      final present = [
        for (final id in r.applianceIds) ...appliances.where((x) => x.id == id).take(1),
      ];
      if (present.isEmpty) continue;
      String? why;
      for (final a in present) {
        final issue = issueOf?.call(a);
        if (issue != null && issue.mark == KioskTileMark.unusable) {
          why = issue.text;
          break;
        }
      }
      if (why == null) return (r, present.first, null);
      firstBlocked ??= (r, present.first, why);
    }
    return firstBlocked;
  }

  @override
  Widget build(BuildContext context) {
    // 가전은 왼쪽 그림이 말한다 — 부제는 무엇을 하는지 한 줄(실패널 10/24: 이름이 길면 부제가 잘렸다). 읽을 때는 가전 이름까지.
    // 지금 할 수 없으면 부제 자리에 이유(가전 줄 '!'와 같은 말) — '실행하기'는 흐리게, 눌러도 부르지 않는다.
    final blocked = blockedReason;
    // 화면에는 짧게 — 왜 못 쓰는지는 위 안내 띠가 말한다(실패널 10/24: 긴 이유가 카드에서 잘렸다). 읽을 때는 이유까지.
    final sub = blocked != null ? '지금은 쓸 수 없어요' : (sizeLabel.isNotEmpty ? sizeLabel : appliance.tileName);
    final spoken = [appliance.tileName, if (sizeLabel.isNotEmpty) sizeLabel].join(' · ');
    return Column(
      key: const ValueKey('idle-featured'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('무엇을 할까요?',
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: headSize, height: 1.25, fontWeight: FontWeight.w700, color: KioskColors.ink)),
        const SizedBox(height: headGap),
        Semantics(
          button: true,
          enabled: blocked == null,
          label: blocked == null ? '${routine.name}, $spoken, 실행하기' : '${routine.name}, $spoken, 실행하기, $blocked',
          excludeSemantics: true,
          child: Material(
            color: KioskColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: KioskColors.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('idle-featured-run'),
              onTap: blocked == null ? onRun : null,
              child: SizedBox(
                height: cardHeight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: KioskSpace.sm),
                  child: Row(children: [
                    KioskArtTile(category: appliance.category, fallbackIcon: appliance.icon, size: 68),
                    const SizedBox(width: KioskSpace.sm),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(routine.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: KioskType.body, height: 1.2, fontWeight: FontWeight.w700, color: KioskColors.ink)),
                          KioskText(sub,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: KioskType.caption,
                                  height: 1.2,
                                  color: blocked == null ? KioskColors.muted : KioskColors.warning)),
                        ],
                      ),
                    ),
                    const SizedBox(width: KioskSpace.xs),
                    // 주 행동 모양(청록 면) — 누르면 확인 카드가 먼저 뜬다.
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: KioskSpace.md, vertical: KioskSpace.sm),
                      // 할 수 없으면 채운 면 대신 옅은 테두리·흐린 글자(눌리는 모양이 아니다).
                      decoration: BoxDecoration(
                          color: blocked == null ? KioskColors.primary : Colors.transparent,
                          border: blocked == null ? null : Border.all(color: KioskColors.border),
                          borderRadius: BorderRadius.circular(KioskSizes.buttonRadius)),
                      child: Text('실행하기',
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(
                              fontSize: KioskType.body,
                              fontWeight: FontWeight.w700,
                              color: blocked == null ? KioskColors.onAccent : KioskColors.muted)),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
