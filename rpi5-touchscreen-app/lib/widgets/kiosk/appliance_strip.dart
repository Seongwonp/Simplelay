import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../theme/kiosk_colors.dart';
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

/// 바로 쓸 수 없는 가전 — 띠가 '설정이 필요해요'·'연결이 안 돼요'인 것([kioskTileBand]와 같은 판정). 줄 맨 뒤에 선다
/// (평가 13차 10/18: 실패널 첫 장에 '설정이 필요해요'가 둘이고 실제로 쓰는 LG 공기청정기는 둘째 장으로 밀렸다).
bool _notReadyYet(ApplianceMap a) =>
    a.needsPanelMapping || a.readiness == 'needs_setup' || a.readiness == 'disconnected';

/// 등록된 가전 아이콘 줄 — 한 번에 [perPage]개, 화살표·손가락 밀기로 넘긴다.
///
/// 상태는 색만으로 말하지 않는다: 쉬는 가전은 회색 아이콘뿐이고(글자 "대기"는
/// 쓰지 않는다), 동작 중은 강조색 테와 "동작 중", 확인 필요는 노란색과
/// "확인 필요"에 느린 숨쉬기 3번(동작 줄이기 설정이면 멈춘 테)을 준다.
///
/// ThinQ 가전은 아이콘 옆에 'ThinQ' 경로 배지를 단다(상세 화면과 같은 배지). 실행 중이면
/// 가전이 돈다는 뜻의 "동작 중" 대신 허브가 처리 중이라는 "설정 변경 중"으로 말한다
/// (2026-10-15 외부 검토 L2) — 허브는 설정을 보냈을 뿐, 가전이 돌기 시작한 것을 본 게 아니다.
///
/// 켜짐(2026-10-16): 서버가 최근 ThinQ 조회로 전원이 켜진 것을 본 가전은 초록 "켜짐"(확인 완료 색)을 달고
/// 쉬는 가전보다 앞에 선다. 상태를 모르면 아무 글자도 달지 않는다(지어내지 않는다).
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

  /// 지금 쓸 수 없는 가전(평가 3차 10/18) — 누름 장치 연결이 끊기면 누름 장치가 누르는 가전. 타일을 흐리게 하고
  /// '지금 못 써요'라고 말한다. 누르면 무엇을 할지는 평소 화면이 정한다(연결 창). LG 가전은 넣지 않는다.
  final Set<String> unavailable;

  /// [unavailable]이 비상 버튼 때문인가 — 띠를 빨강으로(평가 6차 10/18). 아니면(누름 장치 끊김) 회색.
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
                      style: const TextStyle(fontSize: KioskType.caption, color: Colors.white)),
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
                            style: const TextStyle(
                                fontSize: KioskType.caption,
                                color: Colors.white)),
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
                    child: Icon(icon, size: 34, color: Colors.white),
                  ),
                ),
                const SizedBox(height: 2),
                Text(word,
                    maxLines: 1,
                    softWrap: false,
                    style: const TextStyle(fontSize: KioskType.caption, color: Colors.white)),
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

class _StripItemState extends State<_StripItem>
    with SingleTickerProviderStateMixin {
  // 확인 필요의 느린 숨쉬기 — 2.4초 한 번씩 세 번만(초당 3회 이상 깜빡임 금지,
  // 몇 초 뒤 멈춤). 끝나면 멈춘 테로 남는다.
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );
  int _breaths = 0;

  @override
  void initState() {
    super.initState();
    _breath.addStatusListener((s) {
      if (s == AnimationStatus.completed && ++_breaths < 3) {
        _breath.forward(from: 0);
      }
    });
    if (widget.attention) _breath.forward();
  }

  @override
  void didUpdateWidget(_StripItem old) {
    super.didUpdateWidget(old);
    if (widget.attention && !old.attention) {
      _breaths = 0;
      _breath.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.appliance;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    // 큰 사각 타일(화면 구조 개편 10/18) — 위는 가전(아이콘 · 이름), 아래는 **상태 띠**(색 면 + 아이콘 + 짧은 말).
    // 평가 6차(10/18, 폰 평가 5차와 같은 구조): 모든 타일 아래 회색 '눌러 드려요'가 되풀이돼 1~2 m에서 상태가 갈리지
    // 않았다. 띠 색은 넷뿐이다 — 초록(본체가 **읽은** 켜짐만) · 파랑(작동 중) · 주황(사람이 할 일) · 빨강(비상 버튼),
    // 그 밖은 회색. 색만으로 말하지 않는다 — 띠마다 아이콘과 글이 같이 있다. 상태를 지어내지 않는다.
    final band = kioskTileBand(
      a,
      attention: widget.attention,
      unavailable: widget.unavailable,
      unavailableByEstop: widget.unavailableByEstop,
      running: widget.running,
      on: widget.on,
      off: widget.off,
    );
    final status = band.text;
    final edge = widget.attention
        ? KioskColors.warning
        : widget.running
            ? Colors.white
            : KioskColors.border;
    return Semantics(
      button: true,
      label: '${a.name}${a.isThinq ? '. LG 가전' : ''}, $status. 자세히 보기',
      child: ExcludeSemantics(
        child: Padding(
          // 간격은 오른쪽에만 — 첫 타일 왼쪽 선이 시계·날짜 왼쪽 선과 같다(평가 3차 10/18).
          padding: const EdgeInsets.only(right: KioskApplianceStrip.tileGap),
          child: AnimatedBuilder(
            animation: _breath,
            builder: (context, child) {
              // 확인 필요의 느린 숨쉬기 — 2.4초 한 번씩 세 번만(초당 3회 이상 깜빡임 금지), 끝나면 멈춘 테.
              final t = widget.attention && !reduceMotion
                  ? math.sin(_breath.value * math.pi)
                  : (widget.attention ? 0.6 : 0.0);
              return DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: widget.attention
                      ? [
                          BoxShadow(
                            color: KioskColors.warning.withValues(alpha: 0.30 * t),
                            spreadRadius: 4 * t,
                          ),
                        ]
                      : null,
                ),
                child: child,
              );
            },
            child: Material(
              // 아래 상태 띠가 둥근 모서리를 따르게 자른다.
              clipBehavior: Clip.antiAlias,
              // 지금 못 쓰면 바탕을 꺼진 것처럼 어둡게 — 글은 흐리게, 상태 줄만 또렷하게(무엇 때문인지는 누르면).
              color: widget.unavailable
                  ? KioskColors.bg
                  : widget.running
                      ? KioskColors.surface2
                      : KioskColors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                    color: edge,
                    width: widget.attention || widget.running ? 2 : 1),
              ),
              child: InkWell(
                onTap: widget.onTap,
                customBorder: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: SizedBox(
                  height: widget.tileHeight,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                        KioskSpace.sm, KioskSpace.sm, KioskSpace.sm, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Opacity(
                          key: widget.unavailable ? ValueKey('tile-unavailable-${a.id}') : null,
                          opacity: widget.unavailable ? 0.5 : 1,
                          child: Row(children: [
                          // 타일이 커지면(남는 높이를 쓴 평소 화면, 평가 4차 10/18) 아이콘도 함께 — 빈 타일처럼 보이지 않게.
                          Icon(a.icon,
                              size: (widget.iconBox * 0.58 + (widget.tileHeight - 112) * 0.3)
                                  .clamp(widget.iconBox * 0.58, 44)
                                  .toDouble(),
                              color: widget.unavailable ? KioskColors.muted : Colors.white),
                          const Spacer(),
                          // 연습 가전(서버 이름 표기 '(연습)')은 'LG 가전' 대신 '연습' — 이름에서 뺀 표기를 여기서 말한다(2026-10-18).
                          if (a.isPractice)
                            const Flexible(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: KioskRouteBadge(key: ValueKey('tile-practice'), label: '연습'),
                              ),
                            )
                          else if (a.isThinq)
                            const Flexible(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: KioskRouteBadge(label: 'LG 가전'),
                              ),
                            ),
                        ])),
                        const Spacer(),
                        Text(
                          a.tileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: widget.labelSize,
                              height: 1.15,
                              fontWeight: FontWeight.w700,
                              color: widget.unavailable ? KioskColors.muted : Colors.white),
                        ),
                      ],
                    ),
                        ),
                      ),
                      _TileBand(
                        boxKey: ValueKey('tile-band-${a.id}'),
                        band: band,
                        textKey: ValueKey('tile-status-${a.id}'),
                        fontSize: widget.statusSize,
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
  }
}

/// 가전 타일 아래 상태 띠 한 줄의 말·아이콘·색.
class KioskTileBand {
  const KioskTileBand(this.text, this.icon, this.tone, {this.fill});

  final String text;
  final IconData icon;

  /// 아이콘·글자 색.
  final Color tone;

  /// 띠 면 색. null이면 [tone]을 띠 농도([KioskSizes.bandTint])로 깐다.
  final Color? fill;

  Color get face => fill ?? tone.withValues(alpha: KioskSizes.bandTint);
}

/// 회색 띠 면 — 준비됨·모름·누름 장치 끊김. 색 있는 띠보다 옅다.
const Color kTileBandGrey = Color(0x1FAEB3C0);

/// 가전 타일의 상태 띠(평가 6차 10/18). 우선순위: 확인 필요 → 지금 못 씀(비상 버튼 빨강 · 누름 장치 끊김 회색) →
/// 작동 중 → 켜짐(LG 가전 조회로 본 것만 초록) → 설정이 필요해요(사진 위치를 맞추지 않은 사용자 가전, 폰과 같은 판정) →
/// 서버 준비 판정(연결·설정) → 준비됐어요(서버가 실행을 받아 준다고 말한 때만) → 모르면 '확인 전이에요'.
KioskTileBand kioskTileBand(
  ApplianceMap a, {
  bool attention = false,
  bool unavailable = false,
  bool unavailableByEstop = false,
  bool running = false,
  bool on = false,
  bool off = false,
}) {
  if (attention) return KioskTileBand('확인 필요', Icons.error_outline, KioskColors.warning);
  if (unavailable) {
    // 이유는 누르면 연다(비상 버튼 풀기 안내·누름 장치 연결 창).
    return unavailableByEstop
        ? KioskTileBand('지금 못 써요', Icons.report, KioskColors.danger)
        : KioskTileBand('지금 못 써요', Icons.link_off, KioskColors.muted, fill: kTileBandGrey);
  }
  if (running) {
    // ThinQ는 허브가 설정을 보냈을 뿐 가전이 도는 것을 본 게 아니다(2026-10-15 외부 검토 L2) — '바꾸는 중'.
    return KioskTileBand(a.isThinq ? '바꾸는 중' : '작동 중', Icons.autorenew, KioskColors.running);
  }
  if (on) return KioskTileBand('켜져 있어요', Icons.power_settings_new, KioskColors.confirmed);
  // 꺼짐도 본체가 읽은 것만(평가 10차 10/18 — 꺼진 공기청정기가 손 아이콘 '준비됐어요'로 보였다, 폰은 '꺼져 있어요').
  // 회색 — 문제가 아니다. 손 아이콘 대신 전원 아이콘. 모르면 아래 종전 판정.
  if (off && a.isThinq) {
    return KioskTileBand('꺼져 있어요', Icons.power_settings_new, KioskColors.muted, fill: kTileBandGrey);
  }
  if (a.needsPanelMapping) {
    return KioskTileBand('설정이 필요해요', Icons.priority_high_rounded, KioskColors.warning);
  }
  return switch (a.readiness) {
    'disconnected' => KioskTileBand('연결이 안 돼요', Icons.link_off, KioskColors.warning),
    'needs_setup' => KioskTileBand('설정이 필요해요', Icons.priority_high_rounded, KioskColors.warning),
    // 체크는 '됐어요'로 읽힌다 — 준비는 누를 수 있다는 손가락(폰과 같은 그림). 눌림을 확인했다는 뜻이 아니라 회색.
    'operable' when a.canExecute =>
      KioskTileBand('준비됐어요', Icons.touch_app_outlined, KioskColors.muted, fill: kTileBandGrey),
    _ => KioskTileBand('확인 전이에요', Icons.help_outline, KioskColors.muted, fill: kTileBandGrey),
  };
}

class _TileBand extends StatelessWidget {
  const _TileBand({required this.boxKey, required this.band, required this.textKey, required this.fontSize});

  /// 띠 면(DecoratedBox)의 열쇠 — 시험이 면 색을 본다.
  final Key boxKey;
  final KioskTileBand band;
  final Key textKey;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final grey = band.fill != null;
    return DecoratedBox(
      key: boxKey,
      decoration: BoxDecoration(color: band.face),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: KioskSpace.sm, vertical: 5),
        child: Row(children: [
          Icon(band.icon, size: fontSize * 1.15, color: band.tone),
          const SizedBox(width: 6),
          // 말줄임 대신 칸에 맞춰 살짝 줄인다 — 잘리면 뜻이 사라진다(평가 5차 10/18).
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                band.text,
                key: textKey,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  fontSize: fontSize,
                  height: 1.2,
                  fontWeight: grey ? FontWeight.w600 : FontWeight.w700,
                  // 작동 중은 흰 글자(파랑은 아이콘·면) — 색 있는 상태는 그 색 글자.
                  color: band.tone == KioskColors.running ? Colors.white : band.tone,
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
