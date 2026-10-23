part of '../home_screen.dart';

class _ApplianceGrid extends StatelessWidget {
  const _ApplianceGrid({
    required this.appliances,
    required this.statusOf,
    required this.verifyNoteOf,
    required this.onOpen,
    required this.onAdd,
  });

  final List<ApplianceMap> appliances;

  /// 상태 줄과 별개의 '확인 주행' 보조 줄([verifyPassTileNote]). 없으면 null.
  final String? Function(ApplianceMap) verifyNoteOf;

  /// 타일 상태(`models/display_status.dart`의 순수 함수).
  final TileStatus Function(ApplianceMap) statusOf;
  final void Function(ApplianceMap) onOpen;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final names = distinctTileNames(appliances);
    final ordered = homeApplianceOrder(appliances);
    Widget card(ApplianceMap a) => _ApplianceCard(
          appliance: a,
          name: names[a.id] ?? a.name,
          status: statusOf(a),
          verifyNote: verifyNoteOf(a),
          onTap: () => onOpen(a),
        );
    // 연습 가전은 따로 '연습해 보기' 구역(결선 모의 평가 10/18 — 실제 '세탁기'(누름 장치용)와 'LG 세탁기'(연습)가 나란히 있어
    // 헷갈렸다). 이름 데이터는 그대로 두고 자리만 나눈다. '가전 추가'는 실제 가전 구역 끝.
    final practice = [for (final a in ordered) if (isPracticeAppliance(a)) card(a)];
    final real = <Widget>[
      for (final a in ordered) if (!isPracticeAppliance(a)) card(a),
      _AddCard(onTap: onAdd),
    ];
    if (practice.isEmpty) return _grid(context, real);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _grid(context, real),
        const SizedBox(height: AppSpace.xl),
        const _SectionTitle('연습해 보기', key: Key('home-practice-section')),
        _grid(context, practice),
      ],
    );
  }

  /// 칸 묶음 하나 — 보통 글씨는 두 칸씩, 큰 글씨는 한 칸씩.
  Widget _grid(BuildContext context, List<Widget> cards) {
    // 큰 글씨(120% 넘음)에서는 한 칸씩. 두 칸에 두면 가전 이름(20)이 한 글자씩 꺾인다(평가 5차 10/18: 130%에서 '전자레인|지').
    if (MediaQuery.textScalerOf(context).scale(1) > 1.2) {
      return Column(
        children: [
          for (var i = 0; i < cards.length; i++)
            Padding(
              padding: EdgeInsets.only(bottom: i + 1 < cards.length ? AppSpace.md : 0),
              child: cards[i],
            ),
        ],
      );
    }
    // 두 칸씩 줄을 세운다. GridView의 고정 높이는 큰 글씨에서 글자를 자른다 --
    // 줄마다 높이를 내용에 맞춘다.
    return Column(
      children: [
        for (var i = 0; i < cards.length; i += 2)
          Padding(
            padding: EdgeInsets.only(bottom: i + 2 < cards.length ? AppSpace.md : 0),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: cards[i]),
                  const SizedBox(width: AppSpace.md),
                  Expanded(
                    child: i + 1 < cards.length
                        ? cards[i + 1]
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

}

/// 가전 타일 — 아이콘 + 이름만(사용자 결정 2026-10-19: 아래 상태 글자 띠가 너무 복잡했다. 키오스크와 같은 규칙).
///
/// - 밝기 = 켜짐·작동 중(사용자 결정 10/19, 두 번째): 밝게(본문 글자색 아이콘·이름)는 [tileLit]일 때만, 그 밖은 흐리게
///   ([AppColorsX.appTileDim]). 카드 면은 바꾸지 않는다. LG 가전은 본체가 **읽은** 켜짐만 밝다.
/// - 문제가 있을 때만 오른쪽 위 작은 표시 하나([TileStatus.issue] 또는 자리 확인 보조 줄) — 쓸 수 없음 '!',
///   확인 전·모름 '?', 설정 남음 톱니. 누르면 말풍선으로 한두 문장, 화면 읽기는 그 문장을 그대로 읽는다.
/// - 버튼 조작 중은 잉크색 테두리 + 진행 막대(글자 없이 — 화면 읽기 이름이 말한다).
/// 다른 곳의 상태 안내(홈 '해야 할 일' 등)는 그대로다.
