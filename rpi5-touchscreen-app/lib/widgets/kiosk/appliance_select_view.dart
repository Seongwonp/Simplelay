import 'package:flutter/material.dart';

import '../../theme/kiosk_tokens.dart';

import '../../models/appliance.dart';
import '../../theme/kiosk_colors.dart';
import 'kiosk_back_button.dart';
import 'appliance_art.dart';
import 'idle_top.dart';
import 'kiosk_text.dart';
import 'route_badge.dart';

/// 수동 조작 진입 시 가전 선택 — 키오스크는 특정 가전 전속이 아니라
/// 공간의 가전들을 다루는 허브다.
///
/// 이전에는 "제어 가전"이 설정 오버레이(점 3연타 진입) 안의 칩이었다.
/// 고령 사용자가 가전을 바꾸려면 숨은 설정을 찾아야 했고, 설정 화면에
/// 왜 전자레인지·인덕션이 떠 있는지 맥락도 없었다. 조작하려는 순간에
/// 묻는 것이 흐름상 자연스럽고(NN/g: 설정보다 과업 흐름 안에서),
/// 폰에서 추가한 가전도 서버 목록으로 함께 나타난다.
class KioskApplianceSelectView extends StatelessWidget {
  const KioskApplianceSelectView({
    super.key,
    required this.appliances,
    required this.lastUsedId,
    required this.onSelect,
    this.onCancel,
    this.onMenu,
  });

  /// 위 오른쪽 '메뉴'(처음 화면과 같은 단추·같은 창, QA 10/25). null이면 두지 않는다.
  final VoidCallback? onMenu;

  final List<ApplianceMap> appliances;

  /// 지난번에 조작한 가전 — 카드에 "지난번" 배지로 표시해 재선택을 돕는다.
  final String? lastUsedId;
  final ValueChanged<ApplianceMap> onSelect;
  /// '뒤로'. null이면 두지 않는다 — 아래 '가전' 탭 화면이라 탭으로 오간다(10/25 사용자: 탭 화면에 뒤로가 어색).
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: KioskColors.bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // 뒤로가기 — 수동 조작 화면과 같은 단추(흰 화살표 + '뒤로', UI 평가 4차 10/17)
                if (onCancel case final back?) ...[KioskBackButton(onTap: back), const SizedBox(width: 14)],
                Expanded(
                  child: Text(
                    '어떤 가전을 쓸까요?',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: KioskType.status,
                      fontWeight: FontWeight.w700,
                      color: KioskColors.ink,
                    ),
                  ),
                ),
                if (onMenu case final open?) KioskIdleMenuButton(onTap: open),
              ],
            ),
            const SizedBox(height: 20),
            Expanded(
              // 0대는 정상 상태다(마지막 가전을 폰에서 삭제한 직후, B11) —
              // GridView는 crossAxisCount 0으로 죽으므로 먼저 가른다.
              child: appliances.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add_home_outlined,
                              size: 44, color: KioskColors.muted),
                          SizedBox(height: 14),
                          Text(
                            '아직 등록한 가전이 없어요',
                            style: TextStyle(
                              fontSize: KioskType.body,
                              fontWeight: FontWeight.w600,
                              color: KioskColors.ink,
                            ),
                          ),
                          SizedBox(height: 8),
                          Text(
                            '휴대폰 앱에서 가전을 추가하면 여기에 나타나요',
                            style: TextStyle(
                                fontSize: KioskType.caption, color: KioskColors.muted),
                          ),
                        ],
                      ),
                    )
                  : GridView.count(
                      crossAxisCount:
                          appliances.length <= 4 ? appliances.length : 4,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 14,
                      childAspectRatio: 1.1,
                      children: [
                        for (final appliance in appliances)
                          _ApplianceCard(
                            appliance: appliance,
                            isLastUsed: appliance.id == lastUsedId,
                            onTap: () => onSelect(appliance),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 칸 아래 표시 자리 높이 — 표시 글(보조 크기)과 위아래 여백. 큰 글씨에서도 칩이 잘리지 않게 넉넉히.
const double _marksHeight = 32;

class _ApplianceCard extends StatelessWidget {
  const _ApplianceCard({
    required this.appliance,
    required this.isLastUsed,
    required this.onTap,
  });

  final ApplianceMap appliance;
  final bool isLastUsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${appliance.displayName} 조작하기'
          '${appliance.isThinq ? '. LG 가전' : ''}'
          '${isLastUsed ? '. 지난번에 썼어요' : ''}',
      child: Material(
        color: KioskColors.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isLastUsed
                    ? KioskColors.muted
                    : KioskColors.border,
                width: isLastUsed ? 1.5 : 1,
              ),
            ),
            // 가전이 많고 큰 글씨면 칸이 낮다 — 넘치면 칸 안 내용을 통째로 살짝 줄인다(폭은 칸 그대로라 이름은 낱말 단위로 꺾인다).
            child: LayoutBuilder(builder: (context, box) => Center(child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(
              width: box.maxWidth,
              child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 폰과 같은 가전 그림(시안 B 10/24).
                KioskArtTile(category: appliance.category, fallbackIcon: appliance.icon, size: 72),
                const SizedBox(height: 10),
                // 낱말 단위로 줄을 바꾼다(출시 검토 10/18 — '연습 전자레인/지'처럼 한 글자가 떨어졌다).
                KioskText(
                  appliance.displayName,
                  textKey: ValueKey('appliance-select-name-${appliance.id}'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: KioskType.body,
                    fontWeight: FontWeight.w600,
                    color: KioskColors.ink,
                  ),
                ),
                // 표시(LG 가전·지난번)는 칸마다 같은 높이의 자리에(평가 12차 10/18 — '지난번' 칩이 있는 칸만 아이콘·이름이
                // 위로 밀려 칸마다 높이가 달랐다). 표시가 없어도 자리는 비워 둔다.
                const SizedBox(height: 6),
                SizedBox(
                  key: const ValueKey('appliance-select-marks'),
                  height: _marksHeight,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // ThinQ 가전은 버튼판이 없다 -- 고르기 전에 경로를 글자로 말한다.
                      if (appliance.isThinq) const KioskRouteBadge(label: 'LG 가전'),
                      if (appliance.isThinq && isLastUsed) const SizedBox(width: 6),
                      if (isLastUsed)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(
                            color: KioskColors.surface2,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '지난번',
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                              fontSize: KioskType.caption,
                              color: KioskColors.success,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            )))),
          ),
        ),
      ),
    );
  }
}
