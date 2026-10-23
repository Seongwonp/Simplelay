part of '../home_screen.dart';

class _ApplianceCard extends ConsumerWidget {
  const _ApplianceCard({
    required this.appliance,
    required this.name,
    required this.status,
    required this.onTap,
    this.verifyNote,
  });

  final ApplianceMap appliance;

  /// 타일에 적을 이름([distinctTileNames]) — 같은 이름이 둘이면 " (2)"가 붙는다.
  final String name;

  /// '확인 주행' 보조 줄. 상태가 평소일 때 설정 톱니 표시의 문장이 된다.
  final String? verifyNote;

  /// 타일 상태. "돌아가는 중"은 없다 — 버튼 조작 진행·준비 여부까지만.
  final TileStatus status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = appliance;
    final s = status;
    final active = s.tone == TileTone.active;
    final run = ref.watch(executionStatusProvider);
    final total = run.totalSteps ?? run.steps.length;
    final done = run.completedSteps;
    // 자리 확인을 실제로 마치지 못한 가전(평가 10차 판정 그대로) — 평소 상태일 때만 설정 톱니로. 실행을 막지 않는다.
    final note = verifyNote;
    final issue = s.issue ?? (s.tone == TileTone.ready && note != null ? TileIssue(TileMark.setup, note) : null);
    final practice = isPracticeAppliance(a);
    // 연습 가전 화면 이름은 '연습 세탁기'(접근성 감사 10/18 — 실제 '세탁기'와 헷갈렸다, 본체와 같은 규칙).
    final shownName = practiceDisplayName(name);
    // 밝기 = 켜짐·작동 중(10/19, 두 번째) — 아이콘·이름 같은 색. 강조색(골드)은 쓰지 않는다(주 행동 전용).
    final fg = tileLit(s) ? context.appInk : context.appTileDim;
    // 문제가 아닌 상태 말 — 화면 읽기 이름에만(화면 글자는 없다). 밝기(색)만으로 말하지 않는다(10/19, 두 번째):
    // 쉬는 누름 장치 가전은 '지금 누르고 있지 않아요' — 허브가 지금 누르고 있지 않다는 뜻까지만(가전이 꺼졌다고 단정하지 않는다).
    // LG 가전 전원을 모르면 넣지 않는다 — '?' 표시 문장이 말한다.
    final word = switch (s.tone) {
      TileTone.on || TileTone.off || TileTone.active => s.text,
      _ when !a.isThinq => '지금 누르고 있지 않아요',
      _ => null,
    };
    final card = Semantics(
      button: true,
      // excludeSemantics라 아래 글자가 따로 읽히지 않는다 — 문제 문장은 오른쪽 위 표시가 따로 읽는다.
      label: [
        if ((a.location ?? '').isNotEmpty) '${a.location} $shownName' else shownName,
        // 연습 가전에는 'LG 가전'을 쓰지 않는다(출시 검토 10/18 — 실제 LG 가전과 헷갈렸다).
        if (a.isThinq && !practice) 'LG 가전',
        if (practice) '연습',
        if (word != null && word.isNotEmpty) word,
      ].join(', '),
      excludeSemantics: true,
      child: Card(
        clipBehavior: Clip.antiAlias,
        // 버튼 조작 중일 때만 테두리. 강조색(갈색)은 주 행동에만 — 잉크색 테두리로.
        shape: active
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: context.appInk, width: 2))
            : null,
        child: InkWell(
          key: Key('appliance-card-${a.id}'),
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 가전 그림 + 오른쪽 위 '연습' 표지 — 문제 표시가 있으면 그 왼쪽(겹치지 않게 자리를 비운다).
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          key: Key('appliance-icon-${a.id}'),
                          width: 64,
                          height: 64,
                          alignment: Alignment.center,
                          child: ApplianceArtwork(category:a.category,size:64,color:fg),
                        ),
                        // 남는 폭은 배지 칸 하나가 가진다(Spacer와 나누면 배지가 반으로 줄었다).
                        Expanded(
                          child: practice
                              ? Align(
                                  alignment: Alignment.topRight,
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: DemoBadge(key: Key('appliance-practice-${a.id}')),
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                        if (issue != null) const SizedBox(width: _TileMarkButton.hit - AppSpace.sm),
                      ],
                    ),
                    const SizedBox(height: AppSpace.sm),
                    Text(
                      shownName,
                      style: TextStyle(fontSize: AppFont.cardTitle, fontWeight: FontWeight.w700, color: fg),
                    ),
                    if ((a.location ?? '').isNotEmpty)
                      Text(a.location!,
                          style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
                    // 'LG 가전'은 테두리 칩이 아니라 이름 아래 작은 글자(평가 14차 10/18: 반복 장식).
                    if (a.isThinq && !practice)
                      Text('LG 가전',
                          key: Key('appliance-lg-${a.id}'),
                          style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
                  ],
                ),
              ),
              if (s.progress)
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpace.md, 0, AppSpace.md, AppSpace.md),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      key: Key('appliance-progress-${a.id}'),
                      minHeight: 5,
                      value: total > 0 ? (done / total).clamp(0.0, 1.0) : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (issue == null) return KeyedSubtree(key: Key('appliance-tile-${a.id}'), child: card);
    return Stack(key: Key('appliance-tile-${a.id}'), fit: StackFit.passthrough, children: [
      card,
      // 카드 안 오른쪽 위 — 보이는 원은 작게, 누르는 자리는 48dp.
      Positioned(
        top: AppSpace.xs,
        right: AppSpace.xs,
        child: _TileMarkButton(key: Key('appliance-mark-${a.id}'), issue: issue),
      ),
    ]);
  }
}

/// 타일 오른쪽 위 문제 표시(사용자 결정 10/19, 키오스크 `KioskTileMarkButton`과 같은 모양·문장). 누르면 말풍선
/// (몇 초 뒤 또는 바깥을 누르면 닫힘). 화면 읽기는 문장을 그대로 읽는다(색·모양만으로 말하지 않는다).
class _TileMarkButton extends StatefulWidget {
  const _TileMarkButton({super.key, required this.issue});

  final TileIssue issue;

  /// 누르는 자리 한 변(48dp).
  static const double hit = 48;

  @override
  State<_TileMarkButton> createState() => _TileMarkButtonState();
}

class _TileMarkButtonState extends State<_TileMarkButton> {
  final _tip = GlobalKey<TooltipState>();

  @override
  Widget build(BuildContext context) {
    final mark = widget.issue.mark;
    final unusable = mark == TileMark.unusable;
    final icon = switch (mark) {
      TileMark.unusable => Icons.priority_high_rounded,
      TileMark.unknown => Icons.question_mark_rounded,
      TileMark.setup => Icons.settings_rounded,
    };
    return Semantics(
      button: true,
      label: widget.issue.text,
      onTap: () => _tip.currentState?.ensureTooltipVisible(),
      excludeSemantics: true,
      child: Tooltip(
        key: _tip,
        message: widget.issue.text,
        triggerMode: TooltipTriggerMode.tap,
        showDuration: const Duration(seconds: 4),
        excludeFromSemantics: true,
        textStyle: TextStyle(fontSize: AppFont.caption, color: context.appBackground, height: 1.3),
        decoration: BoxDecoration(color: context.appOnSurfaceSoft, borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
        child: SizedBox.square(
          dimension: _TileMarkButton.hit,
          child: Center(
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: unusable ? context.appWarning : Colors.transparent,
                border: unusable ? null : Border.all(color: context.appMuted, width: 1.5),
              ),
              child: Icon(icon, size: 16, color: unusable ? context.appOnAccent : context.appMuted),
            ),
          ),
        ),
      ),
    );
  }
}

class _AddCard extends StatelessWidget {
  const _AddCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: '가전 추가',
        excludeSemantics: true,
        child: InkWell(
          key: const Key('appliance-add-card'),
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 112),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: context.appBorderSubtle),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add, size: 28, color: context.appMuted),
                const SizedBox(height: AppSpace.xs),
                Text('가전 추가',
                    style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
              ],
            ),
          ),
        ),
      );
}

/// 가전이 0대인 화면에서 **서버 목록 사정**을 한 줄로. 없으면 null.
///
/// 조회 실패와 '서버에 정말 없음'을 같은 빈 화면으로 두지 않는다.
String? _serverCatalogNote(ServerApplianceCatalog catalog) =>
    switch (catalog.status) {
      ServerCatalogStatus.loading => '본체에서 가전 목록을 불러오고 있어요.',
      ServerCatalogStatus.failed => '본체의 가전 목록을 못 불러왔어요. 연결을 봐 주세요.',
      ServerCatalogStatus.loaded || ServerCatalogStatus.unconfigured => null,
    };

/// 설치한 가전이 0대인 홈. **고장이 아니라 시작점**이다 -- 경고색도 오류
/// 문구도 쓰지 않고, 다음에 할 일 하나만 놓는다.
