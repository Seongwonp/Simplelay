import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../theme/kiosk_colors.dart';
import 'appliance_art.dart';
import 'route_badge.dart';
import '../../theme/kiosk_tokens.dart';

/// 평소 화면 아래의 가전 줄에 설 순서 — **확인 필요 → 동작 중 → 켜짐(ThinQ) → 바로 쓸 수 있는 가전 → 설정·연결이 필요한 가전**.
///
/// 같은 무리 안에서는 등록 순서를 지킨다. 뒤쪽 가전이 동작을 시작하면 맨 앞으로
/// 올라온다(UI 확정 §3-1). 끝에서 처음으로 돌아가는 반복은 쓰지 않는다.
/// [on]은 서버가 최근 조회로 **켜져 있다고 본** ThinQ 가전뿐이다(GET /thinq/power, 2026-10-16) —
/// 모르거나 오래된 상태는 들어오지 않는다.
List<ApplianceMap> orderForStrip(
  List<ApplianceMap> appliances, {
  required Set<String> running,
  required Set<String> attention,
  Set<String> on = const {},
}) {
  int rank(ApplianceMap a) => attention.contains(a.id)
      ? 0
      : running.contains(a.id)
          ? 1
          : on.contains(a.id)
              ? 2
              : _notReadyYet(a)
                  ? 4
                  : 3;
  final indexed = [
    for (var i = 0; i < appliances.length; i++) (i, appliances[i]),
  ];
  indexed.sort((x, y) {
    final r = rank(x.$2).compareTo(rank(y.$2));
    return r != 0 ? r : x.$1.compareTo(y.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// 바로 쓸 수 없는 가전 — 설정 톱니·연결 '!' 표시인 것([kioskTileIssue]와 같은 판정). 줄 맨 뒤에 선다
/// (평가 13차 10/18: 실패널 첫 장에 '설정이 필요해요'가 둘이고 실제로 쓰는 LG 공기청정기는 둘째 장으로 밀렸다).
bool _notReadyYet(ApplianceMap a) =>
    a.needsPanelMapping || a.readiness == 'needs_setup' || a.readiness == 'disconnected';

/// 등록된 가전 타일 줄 — 한 번에 [perPage]개, 화살표·손가락 밀기로 넘긴다.
///
/// 타일은 아이콘 + 이름만(사용자 결정 2026-10-19 — 아래 상태 글자 띠를 없앴다). 상태는 색만으로 말하지 않는다:
/// - 밝기 = 켜짐·작동 중(사용자 결정 10/19, 두 번째): 밝게(흰 아이콘·흰 이름)는 [kioskTileLit]일 때만, 그 밖은 흐리게
///   ([KioskColors.tileDim]). 카드 면은 바꾸지 않는다. LG 가전 전원을 모르면 흐리게 + '?' 표시.
/// - 문제가 있을 때만 오른쪽 위 작은 표시 하나 — 쓸 수 없음 '!', 확인 전·모름 '?', 설정 남음 톱니.
///   누르면 말풍선으로 한두 문장, 화면 읽기는 그 문장을 그대로 읽는다([KioskTileMarkButton]).
/// - 작동 중은 흰 테, 지난 실행 확인 필요는 노란 테에 느린 숨쉬기 3번(동작 줄이기 설정이면 멈춘 테).
/// LG 가전 실행 중은 화면 읽기에서 '작동 중' 대신 '바꾸는 중'(2026-10-15 외부 검토 L2) — 허브는 설정을 보냈을 뿐이다.
/// 켜진 LG 가전(2026-10-16)은 쉬는 가전보다 앞에 선다.
class KioskApplianceStrip extends StatefulWidget {
  const KioskApplianceStrip({
    super.key,
    required this.appliances,
    required this.running,
    required this.attention,
    this.on = const {},
    this.off = const {},
    this.unavailable = const {},
    this.unavailableByEstop = false,
    required this.onSelect,
    this.perPage = 4,
    this.reservePager = true,
    this.itemWidth = 128,
    this.labelSize = KioskType.body,
    this.statusSize = KioskType.caption,
    this.iconBox = 52,
    this.tileHeight = 112,
    this.compactPager = false,
  });

  /// 좁은 장 넘김(평가 5차 10/18) — 쪽 번호 아래 화살표 하나. 가전이 5개 이상일 때 평소 화면이 한 장에 4개를 넣으려고 쓴다
  /// (넓은 장 넘김 칸 때문에 3개만 들어가 오른쪽이 비었다). 마지막 장이 아니면 '다음', 마지막 장이면 '이전'(두 장)·'처음'(세 장 이상).
  /// 손가락 밀기는 그대로 양쪽으로 넘어간다.
  final bool compactPager;

  final List<ApplianceMap> appliances;
  final Set<String> running;
  final Set<String> attention;

  /// 켜져 있다고 확인된 ThinQ 가전(GET /thinq/power). 모르면 넣지 않는다.
  final Set<String> on;

  /// 꺼져 있다고 확인된 ThinQ 가전(같은 응답의 off, 평가 10차 10/18). 모르면 넣지 않는다.
  final Set<String> off;
  final ValueChanged<ApplianceMap> onSelect;
  final int perPage;

  /// 한 장뿐일 때도 장 넘김 자리를 비워 둘지. 평소 화면은 가전이 한 줄에 다 들어가면(4개까지) 비우지 않고
  /// 타일에 폭을 준다(평가 4차 10/18).
  final bool reservePager;

  /// 가전 한 칸 폭 — 이름(예: 거실 선풍기)을 줄이지 않을 만큼. 평소 화면이 글자 배율에 맞춰 준다.
  final double itemWidth;

  /// 가전 이름·상태 글자 크기와 아이콘 원 지름 — 평소 화면이 위계에 맞춰 준다.
  final double labelSize;
  final double statusSize;
  final double iconBox;

  /// 가전 타일 높이(화면 구조 개편 10/18 — 큰 사각 타일).
  final double tileHeight;

  /// 지금 쓸 수 없는 가전(평가 3차 10/18) — 누름 장치 연결이 끊기면 누름 장치가 누르는 가전. 오른쪽 위 '!' 표시('지금은 쓸 수 없어요…')를 단다. 누르면 무엇을 할지는 평소 화면이 정한다(연결 창). LG 가전은 넣지 않는다.
  final Set<String> unavailable;

  /// [unavailable]이 비상 버튼 때문인가 — 표시 문장이 그 이유를 말한다(10/19).
  final bool unavailableByEstop;

  /// 오른쪽 장 넘김 칸 폭(이전 · 쪽 번호 · 다음). 평소 화면이 타일 폭을 잴 때 뺀다.
  static const double pagerWidth = 60 + 48 + 60;

  /// 좁은 장 넘김 칸 폭([compactPager]).
  static const double compactPagerWidth = 64;

  /// 타일 사이 간격(타일 오른쪽에 둔다 — 첫 타일 왼쪽 선이 줄의 왼쪽 선과 같게).
  static const double tileGap = 12;

  @override
  State<KioskApplianceStrip> createState() => _KioskApplianceStripState();
}

class _KioskApplianceStripState extends State<KioskApplianceStrip> {
  int _page = 0;

  static const double _arrow = 52;

  /// 화살표 칸 폭 — 아래 '이전'·'다음' 한 낱말이 큰 글씨에서도 들어간다.
  static const double _arrowBox = 60;

  /// 두 화살표 사이 쪽 번호 칸.
  static const double _pageBox = 48;

  @override
  void didUpdateWidget(KioskApplianceStrip old) {
    super.didUpdateWidget(old);
    // 앞에 설 가전이 바뀌면(새로 동작 시작·확인 필요) 첫 장으로 — 방금 올라온
    // 가전이 보이지 않는 장에 머물면 "맨 앞으로 올라온다"가 눈에 안 보인다.
    final front = {...widget.attention, ...widget.running, ...widget.on};
    final oldFront = {...old.attention, ...old.running, ...old.on};
    if (front.length != oldFront.length || !front.containsAll(oldFront)) {
      _page = 0;
    }
    final last = _lastPage;
    if (_page > last) _page = last;
  }

  int get _lastPage => widget.appliances.isEmpty
      ? 0
      : (widget.appliances.length - 1) ~/ widget.perPage;

  void _go(int page) {
    final next = page.clamp(0, _lastPage);
    if (next != _page) setState(() => _page = next);
  }

  @override
  Widget build(BuildContext context) {
    final ordered = orderForStrip(widget.appliances,
        running: widget.running, attention: widget.attention, on: widget.on);
    final start = _page * widget.perPage;
    final visible =
        ordered.skip(start).take(widget.perPage).toList(growable: false);
    final hasPrev = _page > 0;
    final hasNext = _page < _lastPage;
    final page = '${_page + 1}/${_lastPage + 1}';

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 손가락으로 밀어 넘기기 — 왼쪽으로 밀면 다음 장.
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v < -150) _go(_page + 1);
        if (v > 150) _go(_page - 1);
      },
      // 타일은 왼쪽 선(시계·날짜와 같은 선)에서 시작하고, 장 넘김은 오른쪽 끝에 이전·쪽 번호·다음으로 모은다
      // (평가 3차 10/18 — 가운데 정렬 + 왼쪽 화살표 자리 때문에 타일이 시계보다 한참 오른쪽에서 시작했다).
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: widget.itemWidth * widget.perPage,
            child: Row(
              children: [
                for (final a in visible)
                  SizedBox(
                    width: widget.itemWidth,
                    child: _StripItem(
                      key: ValueKey('strip-${a.id}'),
                      appliance: a,
                      running: widget.running.contains(a.id),
                      attention: widget.attention.contains(a.id),
                      on: widget.on.contains(a.id),
                      off: widget.off.contains(a.id),
                      unavailable: widget.unavailable.contains(a.id),
                      unavailableByEstop: widget.unavailableByEstop,
                      labelSize: widget.labelSize,
                      statusSize: widget.statusSize,
                      iconBox: widget.iconBox,
                      tileHeight: widget.tileHeight,
                      onTap: () => widget.onSelect(a),
                    ),
                  ),
              ],
            ),
          ),
          // 한 장뿐이면 장 넘김을 그리지 않는다(자리는 지켜 타일 크기가 바뀌지 않게).
          if (_lastPage == 0)
            SizedBox(
                width: widget.reservePager
                    ? (widget.compactPager
                        ? KioskApplianceStrip.compactPagerWidth
                        : KioskApplianceStrip.pagerWidth)
                    : 0)
          else if (widget.compactPager)
            SizedBox(
              width: KioskApplianceStrip.compactPagerWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(page,
                      key: const ValueKey('strip-page'),
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(fontSize: KioskType.caption, color: KioskColors.ink)),
                  const SizedBox(height: 2),
                  hasNext
                      ? _ArrowButton(
                          key: const ValueKey('strip-next'),
                          icon: Icons.chevron_right,
                          label: '다음 가전',
                          word: '다음',
                          page: page,
                          onTap: () => _go(_page + 1),
                        )
                      : _ArrowButton(
                          key: const ValueKey('strip-prev'),
                          icon: _lastPage == 1 ? Icons.chevron_left : Icons.first_page,
                          label: _lastPage == 1 ? '이전 가전' : '처음 가전',
                          word: _lastPage == 1 ? '이전' : '처음',
                          page: page,
                          onTap: () => _go(_lastPage == 1 ? _page - 1 : 0),
                        ),
                ],
              ),
            )
          else
            SizedBox(
              width: KioskApplianceStrip.pagerWidth,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 끝에 닿은 쪽 화살표는 숨기되 자리는 유지한다 — 줄이 흔들리지 않게.
                  hasPrev
                      ? _ArrowButton(
                          key: const ValueKey('strip-prev'),
                          icon: Icons.chevron_left,
                          label: '이전 가전',
                          word: '이전',
                          page: page,
                          onTap: () => _go(_page - 1),
                        )
                      : const SizedBox(width: _arrowBox),
                  // 쪽 번호 — 화살표 가운데 높이. 글자 배율이 커져도 자르지 않고 칸 안에서 줄인다.
                  SizedBox(
                    width: _pageBox,
                    height: _arrow,
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(page,
                            key: const ValueKey('strip-page'),
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                                fontSize: KioskType.caption,
                                color: KioskColors.ink)),
                      ),
                    ),
                  ),
                  hasNext
                      ? _ArrowButton(
                          key: const ValueKey('strip-next'),
                          icon: Icons.chevron_right,
                          label: '다음 가전',
                          word: '다음',
                          page: page,
                          onTap: () => _go(_page + 1),
                        )
                      : const SizedBox(width: _arrowBox),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ArrowButton extends StatelessWidget {
  const _ArrowButton({
    super.key,
    required this.icon,
    required this.label,
    required this.word,
    required this.page,
    required this.onTap,
  });

  final IconData icon;
  final String label;

  /// 단추 아래 글자('다음'·'이전'). 쪽 번호는 두 화살표 사이에 따로 둔다 — '다음 1/3'을 한 줄에 넣으면
  /// 큰 글씨에서 잘렸다(평가 3차 10/18).
  final String word;
  final String page;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: '$label, $page',
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: _KioskApplianceStripState._arrowBox,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Material(
                  color: KioskColors.surface,
                  shape: CircleBorder(
                      side: BorderSide(color: KioskColors.border)),
                  child: SizedBox(
                    width: _KioskApplianceStripState._arrow,
                    height: _KioskApplianceStripState._arrow,
                    child: Icon(icon, size: 34, color: KioskColors.ink),
                  ),
                ),
                const SizedBox(height: 2),
                Text(word,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(fontSize: KioskType.caption, color: KioskColors.ink)),
              ],
            ),
          ),
        ),
      );
}


class _StripItem extends StatefulWidget {
  const _StripItem({
    super.key,
    required this.appliance,
    required this.running,
    required this.attention,
    this.on = false,
    this.off = false,
    this.unavailable = false,
    this.unavailableByEstop = false,
    required this.onTap,
    this.labelSize = KioskType.body,
    this.statusSize = KioskType.caption,
    this.iconBox = 52,
    this.tileHeight = 112,
  });

  final ApplianceMap appliance;
  final bool running;
  final bool attention;
  final bool on;
  final bool off;
  final bool unavailable;
  final bool unavailableByEstop;
  final VoidCallback onTap;
  final double labelSize;
  final double statusSize;
  final double iconBox;
  final double tileHeight;

  @override
  State<_StripItem> createState() => _StripItemState();
}

class _StripItemState extends State<_StripItem> {
  // 확인 필요의 앰버 숨쉬기 테는 없앴다(10/24 시각 QA — 골드 선택 테로 읽혔다). 확인 필요는 '!' 표지만 말한다.

  @override
  Widget build(BuildContext context) {
    final a = widget.appliance;
    // 큰 사각 타일 — 평소에는 아이콘 + 이름만(사용자 결정 10/19: 아래 상태 글자 띠가 너무 복잡했고 '못 써요'는 무례하게
    // 들렸다). 켜짐·작동 중은 아이콘·이름을 밝게, 꺼짐·모름·쉬는 중은 흐리게([kioskTileLit]). 문제가 있을 때만
    // 오른쪽 위 작은 표시 하나([KioskTileMarkButton]), 누르면 부드러운 한두 문장. 상태를 지어내지 않는다.
    final issue = kioskTileIssue(
      a,
      attention: widget.attention,
      unavailable: widget.unavailable,
      unavailableByEstop: widget.unavailableByEstop,
      running: widget.running,
      on: widget.on,
      off: widget.off,
    );
    final word = kioskTileStateWord(a, running: widget.running, on: widget.on, off: widget.off);
    // 밝기 = 켜짐·작동 중(사용자 결정 10/19, 두 번째) — 밝게(흰 아이콘·흰 이름)는 [kioskTileLit]일 때만, 그 밖은 흐리게.
    // 문제('!'·'?'·톱니)라고 따로 흐리게 하지 않는다(옛 규칙: 쓸 수 없으면 반투명 — 실패널에서 '흐림 = 문제'로 읽혔다).
    final fg = kioskTileLit(a, running: widget.running, on: widget.on, off: widget.off)
        ? KioskColors.ink
        : KioskColors.tileDim;
    // 확인 필요는 '!' 표지만 말한다(10/24 시각 QA — 앰버 테·빛이 골드 선택 테로 읽혀 두 칸이 골라진 듯 보였다).
    final edge = widget.running ? KioskColors.ink : KioskColors.border;
    final iconSize = (widget.iconBox * 0.58 + (widget.tileHeight - 112) * 0.3)
        .clamp(widget.iconBox * 0.58, 44)
        .toDouble();
    // 가전 그림은 선이 가늘어 아이콘보다 크게 — 안쪽 여백·이름·'LG 가전' 줄 자리를 남기고 64까지(시안 B 10/24).
    final scaler = MediaQuery.textScalerOf(context);
    final reserve = 2 * KioskSpace.sm +
        scaler.scale(widget.labelSize) * 1.15 +
        scaler.scale(widget.statusSize) * 1.2 +
        KioskSpace.xs;
    final artSize = math.max(iconSize, math.min(64.0, widget.tileHeight - reserve));
    final tile = Semantics(
      button: true,
      // 문제 문장은 표시가 따로 읽는다 — 타일은 이름·종류와 문제가 아닌 상태만.
      label: [
        a.displayName,
        if (a.isPractice) '연습' else if (a.isThinq) 'LG 가전',
        if (word != null) word,
        '자세히 보기',
      ].join(', '),
      child: ExcludeSemantics(
        child: Material(
          clipBehavior: Clip.antiAlias,
          // 카드 면은 밝기 규칙과 상관없다(사용자 결정 10/19, 두 번째 — 쓸 수 없을 때 어둡게 하던 면을 없앴다).
          color: widget.running ? KioskColors.surface2 : KioskColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: edge, width: widget.running ? 2 : 1),
          ),
          child: InkWell(
            onTap: widget.onTap,
            customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: SizedBox(
              height: widget.tileHeight,
              child: Padding(
                padding: const EdgeInsets.all(KioskSpace.sm),
                // 쓸 수 없음 표지(시험·평소 화면이 찾는 열쇠)만 남기고 반투명은 없앴다(10/19, 두 번째).
                child: KeyedSubtree(
                  key: widget.unavailable ? ValueKey('tile-unavailable-${a.id}') : null,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        // 폰 홈과 같은 가전 그림(시안 B 10/24) — 밝기 규칙(켜짐 밝게·꺼짐 흐리게)은 선 색이 말한다.
                        KioskApplianceArt(
                            key: ValueKey('tile-icon-${a.id}'),
                            category: a.category,
                            fallbackIcon: a.icon,
                            size: artSize,
                            color: fg,
                            paper: widget.running ? KioskColors.surface2 : KioskColors.surface),
                        // 연습 가전(서버 이름 표기 '(연습)')은 '연습' 배지 그대로(정직성) — 문제 표시가 있으면 그 왼쪽.
                        // 남는 폭은 배지 칸 하나가 가진다(Spacer와 나누면 배지가 반으로 줄었다).
                        Expanded(
                          child: a.isPractice
                              ? const Align(
                                  alignment: Alignment.centerRight,
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: KioskRouteBadge(key: ValueKey('tile-practice'), label: '연습'),
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                        // 문제 표시 자리(오른쪽 위)를 비워 둔다.
                        if (issue != null) const SizedBox(width: KioskTileMarkButton.hit - KioskSpace.sm),
                      ]),
                      const Spacer(),
                      Text(
                        a.tileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: widget.labelSize,
                            height: 1.15,
                            fontWeight: FontWeight.w700,
                            color: fg),
                      ),
                      // 'LG 가전'은 오른쪽 위 배지가 아니라 이름 아래 작은 글자(10/19 — 오른쪽 위는 문제 표시 자리).
                      if (a.isThinq && !a.isPractice)
                        Text(
                          'LG 가전',
                          key: ValueKey('tile-lg-${a.id}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: widget.statusSize, height: 1.2, color: KioskColors.muted),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Padding(
      // 간격은 오른쪽에만 — 첫 타일 왼쪽 선이 시계·날짜 왼쪽 선과 같다(평가 3차 10/18).
      padding: const EdgeInsets.only(right: KioskApplianceStrip.tileGap),
      child: Stack(children: [
        tile,
        if (issue != null)
          Positioned(
            top: 0,
            right: 0,
            child: KioskTileMarkButton(key: ValueKey('tile-mark-${a.id}'), issue: issue),
          ),
      ]),
    );
  }
}

/// 타일 오른쪽 위 문제 표시의 모양(사용자 결정 10/19) — 문제가 있을 때만 하나.
enum KioskTileMark {
  /// 쓸 수 없음(연결 끊김·비상 버튼·누름 장치 없음·지난 실행을 끝내지 못함) — '!'.
  unusable,

  /// 확인 전·모름 — '?'.
  unknown,

  /// 설정이 남음 — 톱니.
  setup,
}

/// 문제 표시 하나 — 모양과, 누르면 말풍선·화면 읽기로 말할 부드러운 한두 문장.
class KioskTileIssue {
  const KioskTileIssue(this.mark, this.text);
  final KioskTileMark mark;
  final String text;

  @override
  bool operator ==(Object other) => other is KioskTileIssue && other.mark == mark && other.text == text;

  @override
  int get hashCode => Object.hash(mark, text);

  @override
  String toString() => 'KioskTileIssue($mark, $text)';
}

/// 표시 문장 — 폰 `display_status.dart`의 같은 이름 상수와 **같은 말**(키오스크·폰 같은 규칙, 10/19).
const kTileUnusablePress = '지금은 쓸 수 없어요. 누름 장치 연결을 확인해 주세요';
const kTileUnusableEstop = '지금은 쓸 수 없어요. 비상 버튼이 눌려 있어요';
const kTileUnusableLink = '지금은 쓸 수 없어요. 연결을 확인해 주세요';
const kTileLastFailed = '지난번에 끝까지 하지 못했어요. 가전을 한번 봐 주세요';
const kTilePanelSetup = '버튼 자리를 아직 맞추지 않았어요. 가족이 휴대폰에서 설정해요';
const kTileSetupLeft = '아직 설정이 남았어요. 가족이 휴대폰에서 설정해요';
const kTilePowerUnknown = '켜져 있는지 아직 확인하지 못했어요';
const kTileReadyUnknown = '쓸 수 있는지 아직 확인하지 못했어요';

/// 가전 타일의 문제 표시(사용자 결정 10/19). 평소(누름 장치 가전 준비됨·읽은 켜짐/꺼짐·작동 중)는 null — 표시 없음.
///
/// 우선순위(옛 상태 띠와 같은 판정): 지난 실행 확인 필요 → 지금 쓸 수 없음(비상 버튼·누름 장치 끊김) → 작동 중 →
/// 연습 가전(읽은 전원만, 모르면 '?') → 읽은 켜짐·꺼짐 → 위치 미설정(톱니) → 서버 판정(연결 '!'·설정 톱니) →
/// 누름 장치 가전 준비됨(서버가 실행을 받아 준다고 말한 때만, 표시 없음) → 모르면 '?'. 상태를 지어내지 않는다.
KioskTileIssue? kioskTileIssue(
  ApplianceMap a, {
  bool attention = false,
  bool unavailable = false,
  bool unavailableByEstop = false,
  bool running = false,
  bool on = false,
  bool off = false,
}) {
  if (attention) return const KioskTileIssue(KioskTileMark.unusable, kTileLastFailed);
  if (unavailable) {
    return KioskTileIssue(KioskTileMark.unusable, unavailableByEstop ? kTileUnusableEstop : kTileUnusablePress);
  }
  if (running) return null;
  if (a.isPractice) {
    return on || off ? null : const KioskTileIssue(KioskTileMark.unknown, kTilePowerUnknown);
  }
  if (on) return null;
  if (off && a.isThinq) return null;
  if (a.needsPanelMapping) return const KioskTileIssue(KioskTileMark.setup, kTilePanelSetup);
  return switch (a.readiness) {
    'disconnected' => const KioskTileIssue(KioskTileMark.unusable, kTileUnusableLink),
    'needs_setup' => const KioskTileIssue(KioskTileMark.setup, kTileSetupLeft),
    // LG 가전은 누름 장치가 누르지 않는다 — 읽은 전원(위)이 없으면 '?'.
    'operable' when a.canExecute && !a.isThinq => null,
    _ => KioskTileIssue(KioskTileMark.unknown, a.isThinq ? kTilePowerUnknown : kTileReadyUnknown),
  };
}

/// 문제가 아닌 상태 말 — 타일 화면 읽기 이름에만 넣는다(화면 글자는 없다, 10/19). 없으면 null.
///
/// 밝기(색)만으로 말하지 않는다(10/19, 두 번째): 누름 장치 가전이 흐린 것은 '작동 중 아님' — 허브가 지금 누르고 있지 않다는
/// 뜻까지만(가전이 꺼졌다고 단정하지 않는다). LG 가전 전원을 모르면 null — '?' 표시 문장이 말한다.
String? kioskTileStateWord(ApplianceMap a, {bool running = false, bool on = false, bool off = false}) {
  // ThinQ는 허브가 설정을 보냈을 뿐 가전이 도는 것을 본 게 아니다(2026-10-15 외부 검토 L2) — '바꾸는 중'.
  if (running) return a.isThinq ? '바꾸고 있어요' : '작동하고 있어요';
  if (on) return '켜져 있어요';
  if (off && a.isThinq) return '꺼져 있어요';
  if (!a.isThinq) return '지금 누르고 있지 않아요';
  return null;
}

/// 타일을 밝게(흰 아이콘·흰 이름) 그릴지 — 켜짐·작동 중일 때만(사용자 결정 10/19, 두 번째). 폰 `tileLit`과 같은 규칙.
///
/// - 지금 이 가전에서 실행 중([running]) → 밝게. 누름 장치 가전은 켜짐을 읽을 수 없으니 이것뿐이다.
/// - LG 가전(연습 포함)은 본체가 **읽은** 켜짐([on])만 밝게 — 읽은 꺼짐·모름은 흐리게.
/// - 가열 감지(CT)로 켜짐을 아는 길은 아직 이 화면에 오지 않는다(콘센트 모듈 미제작) — 근거가 없으니 짐작하지 않는다.
/// - 문제 표시('!'·'?'·톱니)는 밝기와 별개다.
bool kioskTileLit(ApplianceMap a, {bool running = false, bool on = false, bool off = false}) =>
    running || (on && !off);

/// 타일 오른쪽 위 문제 표시 — 보이는 원은 작게, 누르는 자리는 [KioskTileMarkButton.hit](60px) 정사각형.
/// 누르면 말풍선(몇 초 뒤 또는 바깥을 누르면 닫힘). 화면 읽기는 문장을 그대로 읽는다(색·모양만으로 말하지 않는다).
class KioskTileMarkButton extends StatefulWidget {
  const KioskTileMarkButton({super.key, required this.issue, this.dot = 30});

  final KioskTileIssue issue;

  /// 보이는 원 지름.
  final double dot;

  /// 누르는 자리 한 변.
  static const double hit = 60;

  @override
  State<KioskTileMarkButton> createState() => _KioskTileMarkButtonState();
}

class _KioskTileMarkButtonState extends State<KioskTileMarkButton> {
  final _tip = GlobalKey<TooltipState>();

  @override
  Widget build(BuildContext context) {
    final mark = widget.issue.mark;
    final unusable = mark == KioskTileMark.unusable;
    final icon = switch (mark) {
      KioskTileMark.unusable => Icons.priority_high_rounded,
      KioskTileMark.unknown => Icons.question_mark_rounded,
      KioskTileMark.setup => Icons.settings_rounded,
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
        preferBelow: true,
        textStyle: const TextStyle(fontSize: KioskType.caption, color: Colors.black, height: 1.3),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: KioskSpace.sm + 4, vertical: KioskSpace.sm),
        child: SizedBox.square(
          dimension: KioskTileMarkButton.hit,
          child: Center(
            child: Container(
              width: widget.dot,
              height: widget.dot,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: unusable ? KioskColors.warning : KioskColors.bg,
                border: unusable ? null : Border.all(color: KioskColors.muted, width: 1.5),
              ),
              child: Icon(icon, size: widget.dot * 0.66, color: unusable ? KioskColors.onAccent : KioskColors.ink),
            ),
          ),
        ),
      ),
    );
  }
}
