import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../theme/kiosk_colors.dart';
import 'route_badge.dart';

/// 평소 화면 아래의 가전 줄에 설 순서 — **확인 필요 → 동작 중 → 켜짐(ThinQ) → 나머지**.
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
    required this.onSelect,
    this.perPage = 4,
    this.itemWidth = 128,
    this.labelSize = 33,
    this.statusSize = 33,
    this.iconBox = 62,
  });

  final List<ApplianceMap> appliances;
  final Set<String> running;
  final Set<String> attention;

  /// 켜져 있다고 확인된 ThinQ 가전(GET /thinq/power). 모르면 넣지 않는다.
  final Set<String> on;
  final ValueChanged<ApplianceMap> onSelect;
  final int perPage;

  /// 가전 한 칸 폭 — 이름(예: 거실 선풍기)을 줄이지 않을 만큼. 평소 화면이 글자 배율에 맞춰 준다.
  final double itemWidth;

  /// 가전 이름·상태 글자 크기와 아이콘 원 지름 — 평소 화면이 위계에 맞춰 준다.
  final double labelSize;
  final double statusSize;
  final double iconBox;

  @override
  State<KioskApplianceStrip> createState() => _KioskApplianceStripState();
}

class _KioskApplianceStripState extends State<KioskApplianceStrip> {
  int _page = 0;

  static const double _arrow = 56;

  /// 화살표 칸 폭 — 아래 '다음 1/2' 글자까지 들어간다.
  static const double _arrowBox = 76;

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

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 손가락으로 밀어 넘기기 — 왼쪽으로 밀면 다음 장.
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v < -150) _go(_page + 1);
        if (v > 150) _go(_page - 1);
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 끝에 닿은 쪽 화살표는 숨기되 자리는 유지한다 — 줄이 흔들리지 않게.
          // 화살표만으로는 넘기는 단추인 줄 몰랐다(2026-10-15) — '다음'·'이전' 글자와 몇 번째 장인지 함께.
          hasPrev
              ? _ArrowButton(
                  key: const ValueKey('strip-prev'),
                  icon: Icons.chevron_left,
                  label: '이전 가전',
                  word: '이전',
                  page: '${_page + 1}/${_lastPage + 1}',
                  onTap: () => _go(_page - 1),
                )
              : const SizedBox(width: _arrowBox, height: _arrow),
          const SizedBox(width: 8),
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
                      labelSize: widget.labelSize,
                      statusSize: widget.statusSize,
                      iconBox: widget.iconBox,
                      onTap: () => widget.onSelect(a),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          hasNext
              ? _ArrowButton(
                  key: const ValueKey('strip-next'),
                  icon: Icons.chevron_right,
                  label: '다음 가전',
                  word: '다음',
                  page: '${_page + 1}/${_lastPage + 1}',
                  onTap: () => _go(_page + 1),
                )
              : const SizedBox(width: _arrowBox, height: _arrow),
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

  /// 단추 아래 글자('다음'·'이전')와 지금 장(예: 1/2).
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
                  shape: const CircleBorder(
                      side: BorderSide(color: KioskColors.border)),
                  child: SizedBox(
                    width: _KioskApplianceStripState._arrow,
                    height: _KioskApplianceStripState._arrow,
                    child: Icon(icon, size: 34, color: Colors.white),
                  ),
                ),
                const SizedBox(height: 2),
                Text('$word $page',
                    maxLines: 1,
                    softWrap: false,
                    style: const TextStyle(fontSize: 16, color: Colors.white)),
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
    required this.onTap,
    this.labelSize = 33,
    this.statusSize = 33,
    this.iconBox = 62,
  });

  final ApplianceMap appliance;
  final bool running;
  final bool attention;
  final bool on;
  final VoidCallback onTap;
  final double labelSize;
  final double statusSize;
  final double iconBox;

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
    final Color iconColor;
    final String? status;
    Color? statusColor;
    if (widget.attention) {
      iconColor = KioskColors.warning;
      status = '확인 필요';
    } else if (widget.running) {
      // 동작 중은 일상 상태 — 중립(흰 아이콘·회색 면·멈춘 호), 앰버는 확인 필요에만(2026-10-16 디자인 규격 §1-4).
      iconColor = Colors.white;
      status = a.isThinq ? '설정 변경 중' : '동작 중';
    } else if (widget.on) {
      // 켜짐 — 서버가 ThinQ 조회로 본 전원 상태(2026-10-16). 아이콘은 흰색(쉬는 회색과 구분), 글자는 확인 완료 초록.
      iconColor = Colors.white;
      status = '켜짐';
      statusColor = KioskColors.confirmed;
    } else {
      iconColor = KioskColors.muted;
      status = null;
    }
    return Semantics(
      button: true,
      label: '${a.name}${a.isThinq ? '. 경로 ThinQ' : ''}'
          '${status == null ? '' : ', $status'}. 자세히 보기',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _withRouteBadge(a, AnimatedBuilder(
                  animation: _breath,
                  builder: (context, child) {
                    final t = widget.attention && !reduceMotion
                        ? math.sin(_breath.value * math.pi)
                        : (widget.attention ? 0.6 : 0.0);
                    return Container(
                      width: widget.iconBox,
                      height: widget.iconBox,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: widget.running
                            ? KioskColors.surface2
                            : KioskColors.surface,
                        boxShadow: widget.attention
                            ? [
                                BoxShadow(
                                  color: KioskColors.warning
                                      .withValues(alpha: 0.35 * t),
                                  spreadRadius: 8 * t,
                                ),
                              ]
                            : null,
                      ),
                      child: child,
                    );
                  },
                  child: CustomPaint(
                    // 동작 중 테(멈춘 호) — 도는 애니메이션은 쓰지 않는다.
                    painter: widget.running ? _RunningRing() : null,
                    child: Center(
                      child: Icon(a.icon, size: widget.iconBox * 0.52, color: iconColor),
                    ),
                  ),
                )),
                const SizedBox(height: 5),
                Text(
                  a.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: widget.labelSize, height: 1.15, color: Colors.white),
                ),
                // 상태 줄 자리는 늘 둔다(아이콘 줄 높이가 흔들리지 않게). 큰 글씨
                // 모드에서 글자가 잘리지 않도록 높이는 최소만 정한다.
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 20),
                  child: status == null
                      ? null
                      : Text(
                          status,
                          style: TextStyle(
                            fontSize: widget.statusSize,
                            height: 1.15,
                            fontWeight: FontWeight.w700,
                            color: statusColor ?? iconColor,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// ThinQ 가전이면 아이콘 원 옆에 경로 배지 — 줄 높이는 그대로(원 높이 안에 들어간다),
/// 칸이 좁으면 배지만 줄어든다.
Widget _withRouteBadge(ApplianceMap a, Widget circle) {
  if (!a.isThinq) return circle;
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      circle,
      const SizedBox(width: 6),
      const Flexible(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: KioskRouteBadge(label: 'ThinQ'),
        ),
      ),
    ],
  );
}

class _RunningRing extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(2);
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = Colors.white70,
    );
  }

  @override
  bool shouldRepaint(_RunningRing oldDelegate) => false;
}
