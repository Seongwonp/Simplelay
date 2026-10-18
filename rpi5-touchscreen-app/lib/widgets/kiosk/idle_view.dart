import 'package:flutter/material.dart';
import 'estop_banner.dart';

import '../../models/ambient.dart';
import '../../models/appliance.dart';
import '../../models/kiosk_time.dart';
import '../../models/thinq.dart';
import '../../theme/kiosk_colors.dart';
import 'appliance_strip.dart';
import 'connection_status.dart';
import 'idle_top.dart';
import '../../theme/kiosk_tokens.dart';
import 'kiosk_text.dart';
import 'thinq_panel.dart' show airGradeColor;

/// 평소 화면(UI 확정 2026-09-30 §3-1) — 집에 붙은 시계처럼.
///
/// - 위 줄: 왼쪽 날짜, 설정 진입, 방해 금지, 오른쪽 연결 아이콘 세 개(문제면 "!").
///   방해 금지는 꺼져 있으면 달 아이콘 단추뿐이고(글자가 늘 보이면 켜진 것으로
///   읽혔다, 10/5), 켜져 있으면 채운 칩에 "방해 금지"와 남은 시간을 적는다.
/// - 가운데 왼쪽: 큰 시계와 실내 온도·습도.
/// - 가운데 오른쪽: 인사말 또는 안내 한 줄(서버가 고른 하나), 시간대 예보 4칸.
/// - 아래: 등록된 가전 아이콘 줄(3개씩·큰 글씨 2개씩, 확인 필요 → 동작 중 → 나머지).
///
/// 고정 명령 버튼은 두지 않는다 — 메뉴는 사용자의 가전과 루틴에서 나온다.
/// 누르는 자리는 모두 캔버스 안쪽이라 화면 가장자리 여백(KioskCanvas)을 지킨다.
class KioskIdleView extends StatelessWidget {
  const KioskIdleView({
    super.key,
    required this.now,
    required this.connected,
    this.ambient,
    this.connections = const [],
    this.appliances,
    this.running = const {},
    this.attention = const {},
    this.on = const {},
    this.off = const {},
    this.dndUntil,
    this.quietUntil,
    this.temperature,
    this.humidity,
    this.air,
    this.nextRun,
    required this.onSelectAppliance,
    required this.onOpenConnection,
    required this.onDndGesture,
    this.onSettingsGesture,
    this.onEstopGuide,
  });

  final DateTime now;

  /// 허브(/health)에 닿았나.
  final bool connected;

  /// GET /ambient. null이면(허브에 못 닿음·옛 서버) 인사말만 여기서 만든다.
  final AmbientInfo? ambient;
  final List<ConnectionItem> connections;

  /// 서버에서 받은 가전 목록. null이면 **서버를 아직 못 봤다** — 내장 목록으로
  /// 설치한 적 없는 가전을 세우지 않는다.
  final List<ApplianceMap>? appliances;
  final Set<String> running;
  final Set<String> attention;

  /// 켜져 있다고 확인된 ThinQ 가전(GET /thinq/power, 2026-10-16). 비상 멈춤이 보이는 동안은 달지 않는다.
  final Set<String> on;

  /// 꺼져 있다고 확인된 ThinQ 가전(같은 GET /thinq/power, 평가 10차 10/18). 비상 멈춤이 보이는 동안은 달지 않는다.
  final Set<String> off;
  final DateTime? dndUntil;

  /// 매일 조용한 시간대 안이면 끝 시각("07:00", 2026-10-14). 잠시 쉬기(방해 금지)가 켜져 있으면 그쪽이 먼저 보인다.
  final String? quietUntil;
  final double? temperature;
  final double? humidity;

  /// 공기청정기 센서 공기질(GET /thinq/air, 2026-10-16 — 서버 기억, 클라우드 호출 없음). null이면(모름·오래됨·없음) 줄을 두지 않는다.
  final KioskAirReading? air;

  /// 다음 시각 루틴(GET /routines/next, 외부 평가 10/16 2차 k01). null이면 줄을 두지 않는다.
  final KioskNextRun? nextRun;
  final ValueChanged<ApplianceMap> onSelectAppliance;
  final ValueChanged<ConnectionItem> onOpenConnection;

  /// 위 줄의 방해 금지 단추(꺼짐)·칩(켜짐)을 누르면 방해 금지 선택을 연다.
  final VoidCallback onDndGesture;

  /// 위 줄의 설정 단추(톱니바퀴)를 한 번 누르면 설정 오버레이를 연다.
  final VoidCallback? onSettingsGesture;

  /// 비상 버튼이 눌려 있을 때 상태 칩·못 쓰는 가전 타일을 누르면 — 위 띠의 풀기 안내를 연다(평가 4차 10/18).
  final VoidCallback? onEstopGuide;

  String get _dateStr {
    const wd = ['월', '화', '수', '목', '금', '토', '일'];
    return '${now.month}월 ${now.day}일 ${wd[now.weekday - 1]}요일';
  }

  /// 시계 숫자 — 12시간제 '7:08'. 오전/오후는 옆에 작게(평가 4차 10/18: 시계만 24시, 루틴은 '07:00'으로 섞였다).
  String get _clock => clockDigits(now.hour, now.minute);

  /// 허브에 못 닿을 때의 인사말 — 서버(`services/weather/ambient.py`)와 같은 규칙.
  static String localGreeting(DateTime now) {
    final h = now.hour;
    if (h >= 5 && h < 11) return '좋은 아침이에요.';
    if (h >= 11 && h < 17) return '좋은 오후예요.';
    if (h >= 17 && h < 21) return '편안한 저녁 보내세요.';
    return '편안한 밤 보내세요.';
  }

  /// 실내 온습도 두 조각 — '실내 23°' · '습도 58%'. 큰 글씨에서 한 줄에 다 안 들어가면 조각 사이에서 줄을 바꾼다
  /// ('실내'를 빼지 않는다, 평가 4차 10/18).
  List<String>? get _envParts {
    final t = temperature;
    if (t == null) return null;
    return [
      '실내 ${t.toStringAsFixed(0)}°',
      if (humidity != null) '습도 ${humidity!.toStringAsFixed(0)}%',
    ];
  }

  String _dndRemaining(DateTime until) {
    final diff = until.difference(now);
    if (diff.isNegative) return '';
    if (diff.inMinutes >= 60) {
      final h = diff.inHours;
      final m = diff.inMinutes.remainder(60);
      return m > 0 ? '$h시간 $m분' : '$h시간';
    }
    return '${diff.inMinutes + 1}분';
  }

  @override
  Widget build(BuildContext context) {
    final amb = ambient;
    final greeting = (amb != null && amb.greeting.isNotEmpty)
        ? kioskLine(amb.greeting)
        : kioskLine(localGreeting(now));
    final list = appliances;
    // 큰 글씨 모드(kiosk_screen이 1.22배 textScaler를 얹는다)에서는 같은 800x480
    // 캔버스에 글자만 커지므로, 자르지 않고 **덜 보인다**(2026-10-05 잘림 수리):
    // - 시계는 이미 충분히 커서 배율을 얹지 않고 조금 줄인다.
    // - 안내가 있으면 예보 칸은 숨긴다(보통 글씨에서는 안내와 예보를 함께 보인다).
    // - 가전은 한 장에 2개(보통 3~4개) — 이름·상태를 줄이지 않는다.
    final large = MediaQuery.textScalerOf(context).scale(10) > 10.5;
    final env = _envParts;
    final tip = (amb?.tip != null && amb!.tip!.text.isNotEmpty) ? amb.tip : null;
    // 안내는 한 번에 하나다(UI 확정 §3-1: 확인 필요 가전 → 날씨 → 인사말) —
    // 안내 카드가 있으면 인사말은 접는다. 그 자리에 예보 4칸이 들어간다.
    // 큰 글씨에서는 안내(지금 할 일)가 예보보다 먼저다 — 둘 다 넣으면 아래가 잘린다.
    final showHours = amb != null &&
        amb.hourly.isNotEmpty &&
        !(large && tip != null);
    final showGreeting = tip == null;
    final dnd = dndUntil != null && dndUntil!.isAfter(now) ? dndUntil : null;
    // 본체에 닿지 않으면 지난 연결 목록을 믿지 않는다(평가 7차 10/18 — 끊겼는데 칩이 '모두 정상').
    final connections = connectionsForDisplay(this.connections, connected: connected);
    // 작은 팔 연결이 끊겼나(평가 3차 10/18) — 끊기면 작은 팔이 누르는 가전 타일은 '지금 못 써요'.
    final pressItem = connections.where((c) => c.id == 'press').firstOrNull;
    final pressDown = pressItem?.state == 'error';
    // 비상 버튼이 눌려 있나(평가 4차 10/18) — 위 빨간 띠와 같은 사실을 칩·타일도 말한다. 걸려 있는 동안은 실행이
    // 거절되므로 작은 팔로 누르는 가전은 작은 팔 끊김과 같이 '지금 못 써요'.
    final estop = KioskEstopScope.shownOf(context);
    var hourly = showHours ? amb.hourly.take(4).toList() : const <AmbientHour>[];
    // 가전 4개까지는 장 넘김 없이 한 줄에 다(평가 4차 10/18). 더 많아도 한 장에 4개 + 좁은 장 넘김(평가 5차 10/18 —
    // 넓은 장 넘김 칸 때문에 3개만 들어가 오른쪽이 비었다). 큰 글씨는 2개씩, 넓은 장 넘김.
    final perPage = large ? 2 : 4;
    final pager = large || list == null || list.length > perPage;
    final compactPager = !large;
    final pagerWidth =
        compactPager ? KioskApplianceStrip.compactPagerWidth : KioskApplianceStrip.pagerWidth;

    return _IdleSheetHost(view: this, builder: (sheets) => ColoredBox(
      color: KioskColors.bg,
      child: Padding(
        // 여백을 넉넉히(10/7 "빽빽하다" 수리) — 화면을 끝까지 채우지 않는다.
        padding: const EdgeInsets.fromLTRB(_Idle.side, 14, _Idle.side, 10),
        child: LayoutBuilder(builder: (context, outer) {
          // 가운데(시계·안내) 칸이 실제로 필요한 높이만 두고 남는 높이는 가전 타일을 키우는 데 쓴다(평가 4차 10/18 —
          // 시계·안내와 타일 사이에 빈 띠가 남았다). 화면과 같은 글꼴·배율로 재므로 실패널의 넓은 글꼴에서도 맞다.
          final middleAndStrip = outer.maxHeight - _Idle.topRow - 8 - 8;
          final columns = outer.maxWidth - _Idle.columnGap;
          final leftWidth = columns * 5 / 11;
          final rightWidth = columns * 6 / 11;
          final double strip;
          // 타일을 다 키우고도 남는 높이는 시계를 키우는 데 쓴다(평가 4차 10/18 — 안내·공기·다음 루틴이 없을 때 빈 띠).
          var clockSize = _Idle.clock;
          if (large) {
            strip = _Idle.stripLarge;
          } else {
            final left = _leftColumnHeight(context, leftWidth, env: env, air: air);
            final next = nextRun;
            final nextHeight =
                next == null ? 0.0 : _nextRunGap + _NextRunCard.heightFor(context, next, rightWidth);
            double rightOf(List<AmbientHour> hours) =>
                _rightColumnHeight(context, rightWidth,
                    greeting: showGreeting ? greeting : null,
                    tip: tip,
                    hours: hours,
                    large: large) +
                nextHeight;
            // 예보가 가장 작은 타일 줄로도 들어가지 않으면(실패널의 넓은 글꼴 + 두 줄 안내 + 다음 루틴) 예보를 여기서 접고
            // 예보 없는 높이로 타일을 잰다(평가 5차 10/18 — 예보 자리만큼 가운데가 비어 있었다).
            if (hourly.isNotEmpty && rightOf(hourly) > middleAndStrip - _Idle.strip) {
              hourly = const <AmbientHour>[];
            }
            final right = rightOf(hourly);
            final need = left > right ? left : right;
            strip = (middleAndStrip - need - _Idle.slack)
                .clamp(_Idle.strip, _Idle.stripMax)
                .toDouble();
            // 오른쪽 칸이 더 길면 그 차이만큼은 공짜, 타일을 다 키우고도 남는 높이도 쓴다.
            final spare = middleAndStrip - need - _Idle.slack - strip;
            final grow = (right > left ? right - left : 0.0) + (spare > 0 ? spare : 0.0);
            clockSize += grow.clamp(0, _Idle.clockGrow).toDouble();
          }
          final tileHeight = strip - _Idle.stripPad;
          return Column(children: [
            // 위쪽(화면 구조 개편 10/18): 날짜 · (쉬는 중이면 쉬는 중 칩) · 상태 칩 · 메뉴. 상태 칩·메뉴는 오른쪽에 붙여
            // 재므로 쉬는 중 칩이 켜져도 자리가 바뀌지 않는다(UI 평가 4차 10/17 — 늘 누르던 자리가 밀렸다).
            SizedBox(height: _Idle.topRow, child: Row(children: [
              // 쉬는 중 칩이 켜지면 위 줄이 좁아진다 — 날짜는 말줄임 대신 살짝 줄여 다 보인다.
              // 날짜 옆에 바깥 날씨·기온(사용자 요청 10/18 — 다음 루틴 카드에 가려 예보 칸이 안 보일 때가 많았다).
              // 지금 칸이 없으면 붙이지 않는다([outsideNowSlot]).
              Expanded(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(_dateStr, maxLines: 1, softWrap: false,
                    style: const TextStyle(fontSize: KioskType.body, color: KioskColors.muted)),
                  if (outsideNowSlot(amb, now) case final slot?) ...[
                    const SizedBox(width: KioskSpace.md),
                    _OutsideNow(key: const ValueKey('idle-outside'), slot: slot),
                  ],
                ]))),
              if (dnd != null || quietUntil != null) ...[
                _DndEntry(
                    key: const ValueKey('dnd-chip'),
                    remaining: dnd == null ? null : _dndRemaining(dnd),
                    quietUntil: dnd == null && quietUntil != null ? spokenHhmm(quietUntil!) : null,
                    onTap: onDndGesture),
                const SizedBox(width: KioskSpace.sm),
              ],
              KioskIdleStatusChip(
                items: connections,
                onTap: () {
                  // 비상 버튼이면 위 띠의 풀기 안내, 문제가 하나면 그 연결 창을 바로, 그 밖에는 연결 목록 창.
                  if (estop && onEstopGuide != null) return onEstopGuide!();
                  final (_, _, direct) = connectionSummary(connections);
                  direct != null ? onOpenConnection(direct) : sheets.openConnections();
                },
              ),
              const SizedBox(width: KioskSpace.xs),
              KioskIdleMenuButton(onTap: sheets.openMenu),
            ])),
            const SizedBox(height: 8),
            Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 5, child: SingleChildScrollView(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Clock(ampm: ampmOf(now.hour), digits: _clock, size: large ? 84 : clockSize),
                  if (env != null) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      key: const ValueKey('idle-env'),
                      children: [
                        for (var i = 0; i < env.length; i++)
                          Text(i == 0 ? env[i] : ' · ${env[i]}',
                              maxLines: 1,
                              softWrap: false,
                              style: const TextStyle(
                                  fontSize: _Idle.envText, height: 1.25, color: KioskColors.muted)),
                      ],
                    ),
                  ],
                  // 실내 공기(2026-10-16) — 시계 아래 빈 자리에. 모르면 줄이 없다(지어내지 않는다).
                  if (air != null) ...[
                    const SizedBox(height: _Idle.airGap),
                    _AirLine(key: const ValueKey('idle-air'), air: air!, compact: large),
                  ],
                ],
              ))),
              const SizedBox(width: _Idle.columnGap),
              Expanded(flex: 6, child: LayoutBuilder(builder: (context, box) {
                // 예보는 이 화면에서 가장 덜 중요하다 — 남은 높이에 다 들어가지 않으면
                // (비상정지 띠가 위 한 줄을 차지할 때 등) 반쯤 걸치게 두지 않고 접는다
                // (2026-10-06 실패널: 띠가 생기자 예보 위쪽이 가전 줄에 걸려 잘렸다).
                // 다음 루틴 줄은 예보보다 중요하다 — 자리를 먼저 잡고, 모자라면 예보를 접는다(사용자 질문 10/17:
                // 날씨 안내가 뜨면 다음 루틴 줄이 아래로 밀려 잘렸다).
                // 다음 루틴은 이 칸 아래쪽(가전 줄 바로 위) 큰 카드(평가 3차 10/18 — 오른쪽 위 작은 줄이라 놓쳤다).
                final next = nextRun;
                final nextHeight = next == null
                    ? 0.0
                    : _nextRunGap + _NextRunCard.heightFor(context, next, box.maxWidth);
                // 예보를 접어도 안 들어가면(큰 글씨 + 날씨 안내) 잘린 채 두지 않고 숨긴다 — 날씨 안내가 더 급하다.
                final nextFits = next != null &&
                    _rightColumnHeight(context, box.maxWidth,
                                greeting: showGreeting ? greeting : null,
                                tip: tip,
                                hours: const [],
                                large: large) +
                            nextHeight <=
                        box.maxHeight;
                final hoursFit = hourly.isNotEmpty &&
                    _rightColumnHeight(context, box.maxWidth,
                                greeting: showGreeting ? greeting : null,
                                tip: tip,
                                hours: hourly,
                                large: large) +
                            nextHeight <=
                        box.maxHeight;
                final top = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showGreeting)
                      KioskText(greeting, style: const TextStyle(
                          fontSize: _Idle.greeting, height: 1.25, color: Colors.white)),
                    if (tip != null)
                      _TipCard(key: const ValueKey('ambient-tip'), tip: tip,
                          compact: large),
                    if (hoursFit) ...[
                      SizedBox(height: tip != null ? _Idle.hoursGapTip : _Idle.hoursGap),
                      _Hours(key: const ValueKey('ambient-hours'),
                          hours: hourly, compact: tip != null),
                    ],
                  ],
                );
                if (!nextFits) return SingleChildScrollView(child: top);
                // 예보가 없으면 다음 루틴 카드는 안내 바로 아래(평가 5차 10/18, 실패널 k01 — 예보가 빠진 자리가 가운데에 비었다).
                // 남는 높이는 위에서 타일·시계가 쓴다.
                if (!hoursFit) {
                  return SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        top,
                        const SizedBox(height: _nextRunGap),
                        _NextRunCard(key: const ValueKey('idle-next-run'), next: next),
                      ],
                    ),
                  );
                }
                // 예보가 있으면 다음 루틴 카드는 칸 아래 끝(가전 줄 바로 위)에 붙인다 — 위 안내·예보와 사이 빈칸은 가운데로.
                return SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: box.maxHeight),
                    child: IntrinsicHeight(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          top,
                          const Spacer(),
                          const SizedBox(height: _nextRunGap),
                          _NextRunCard(key: const ValueKey('idle-next-run'), next: next),
                        ],
                      ),
                    ),
                  ),
                );
              })),
            ])),
            const SizedBox(height: 8),
            // 가전 줄은 왼쪽 선(시계·날짜와 같은 선)에서 시작한다(평가 3차 10/18 — 가운데 정렬이라 타일이 시계보다
            // 한참 오른쪽에서 시작했다). 타일 폭은 남은 폭을 장 넘김 칸과 나눠 잰다(장 넘김이 없으면 전부 타일).
            SizedBox(height: strip, child: LayoutBuilder(builder: (context, box) {
              final itemWidth =
                  (box.maxWidth - (pager ? pagerWidth : 0)) / perPage;
              final unavailable = <String>{
                if ((pressDown || estop) && list != null)
                  for (final a in list)
                    if (!a.isThinq) a.id,
              };
              return Align(alignment: list == null || list.isEmpty ? Alignment.center : Alignment.topLeft,
                child: SingleChildScrollView(child: list == null
                  ? const _StripNotice('본체와 연결되면 가전이 보여요')
                  : list.isEmpty ? const _StripNotice('휴대폰 앱에서 가전을 추가해 주세요')
                  : KioskApplianceStrip(appliances: list, running: estop ? const {} : running, attention: estop ? {...attention, ...running} : attention,
                      on: estop ? const {} : on,
                      off: estop ? const {} : off,
                      unavailable: unavailable,
                      // 비상 버튼이면 띠가 빨강, 작은 팔 끊김이면 회색(평가 6차 10/18).
                      unavailableByEstop: estop,
                      // 못 쓰는 가전은 조작판 대신 이유를 연다 — 비상 버튼이면 풀기 안내, 작은 팔 끊김이면 그 연결 창.
                      onSelect: (a) {
                        if (unavailable.contains(a.id)) {
                          if (estop) {
                            onEstopGuide?.call();
                            return;
                          }
                          if (pressItem != null) {
                            onOpenConnection(pressItem);
                            return;
                          }
                        }
                        onSelectAppliance(a);
                      },
                      perPage: perPage,
                      reservePager: pager,
                      compactPager: compactPager,
                      itemWidth: itemWidth,
                      labelSize: _Idle.stripName,
                      statusSize: _Idle.stripStatus,
                      iconBox: 52,
                      tileHeight: tileHeight)));
            })),
          ]);
        }),
      ),
    ));
  }

  /// 왼쪽 칸(시계·온습도·공기)이 [width] 폭에서 차지할 높이 — 가전 타일 높이를 정하는 데만 쓴다.
  static double _leftColumnHeight(BuildContext context, double width,
      {List<String>? env, KioskAirReading? air}) {
    var h = _Idle.clock;
    if (env != null) {
      h += 6 +
          _textHeight(context, env.join(' · '),
              const TextStyle(fontSize: _Idle.envText, height: 1.25), width);
    }
    if (air != null) h += _Idle.airGap + _AirLine.heightFor(context, air, width);
    return h;
  }

  /// 오른쪽 칸(인사말 또는 안내 + 예보)이 [width] 폭에서 차지할 높이. 화면과 같은
  /// 글꼴·배율로 잰다 — 예보를 넣을지 정하는 데만 쓴다.
  static double _rightColumnHeight(BuildContext context, double width,
      {String? greeting, AmbientTip? tip, required List<AmbientHour> hours, required bool large}) {
    var h = 0.0;
    if (greeting != null) {
      h += _textHeight(context, keepWords(greeting),
          const TextStyle(fontSize: _Idle.greeting, height: 1.25), width);
    }
    if (tip != null) h += _TipCard.heightFor(context, tip, width, compact: large);
    if (hours.isNotEmpty) {
      h += tip != null ? _Idle.hoursGapTip : _Idle.hoursGap;
      h += _Hours.heightFor(context, hours, compact: tip != null);
    }
    return h;
  }
}

/// 시계 — '오전' 작게 + '7:08' 크게, 아랫선을 맞춘다. 칸이 좁으면 통째로 줄인다(잘리지 않게).
class _Clock extends StatelessWidget {
  const _Clock({required this.ampm, required this.digits, required this.size});

  final String ampm;
  final String digits;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: size,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            key: const ValueKey('idle-clock'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(ampm,
                  maxLines: 1,
                  softWrap: false,
                  textScaler: TextScaler.noScaling,
                  style: const TextStyle(
                      fontSize: KioskType.status, height: 1, color: KioskColors.muted)),
              const SizedBox(width: KioskSpace.xs),
              Text(digits,
                  maxLines: 1,
                  softWrap: false,
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                      fontSize: size,
                      height: 1,
                      color: Colors.white,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
        ),
      );
}

/// 평소 화면 치수(캔버스 800x480 기준 논리 px, 1920x1080 실패널에서는 2.05배).
///
/// 글자 하한: 고령층 키오스크 지침의 14pt(사용자편의 가이드 체크리스트)는
/// 15.8형(약 139.5 PPI)에서 약 27 물리 px, 캔버스 기준 약 13.2 — 가장 작은
/// 글자(예보 시각 18)도 그 위다. 위계는 시계 > 인사말·안내 > 가전·예보 순.
abstract final class _Idle {
  static const double side = KioskSpace.xl; // 좌우 여백(전 44 — 간격 5단계로 정리 10/18)
  static const double topRow = 64; // 위 줄(전 80)
  static const double envText = KioskType.body; // 실내 온습도(전 22 — 글자 4단계로 정리 10/18)
  static const double airIcon = 28; // 실내 공기 아이콘(2026-10-16)
  static const double columnGap = KioskSpace.xl; // 시계 칸과 안내 칸 사이(전 40)
  static const double greeting = KioskType.status; // 인사말(전 28)
  static const double tipText = KioskType.body; // 안내 카드 글자(전 24)
  static const double tipIcon = 24; // 안내 카드 아이콘(전 30)
  static const double hourLabel = KioskType.caption; // 예보 시각(전 18)
  static const double hourValue = KioskType.body; // 예보 값(전 20)
  static const double hourIcon = 18; // 예보 아이콘(전 26·22)
  static const double hoursGap = KioskSpace.sm;
  static const double hoursGapTip = KioskSpace.xs;
  static const double clock = 104; // 시계 숫자
  static const double clockGrow = 24; // 남는 높이로 시계를 키울 수 있는 한도
  static const double airGap = 14; // 시계·온습도와 공기 줄 사이
  static const double strip = 128; // 가전 줄 최소 높이(전 158) — 남는 높이가 있으면 [stripMax]까지 키운다(평가 4차 10/18)
  static const double stripMax = 164; // 가전 줄 최대 높이 — 타일이 너무 커져 시계보다 무거워지지 않게
  static const double stripLarge = 156; // 큰 글씨 가전 줄 높이
  static const double stripPad = 16; // 줄 높이 − 타일 높이
  static const double slack = 8; // 가운데 칸 여유(실패널 글꼴이 시험 글꼴보다 넓다)
  static const double stripName = KioskType.body; // 가전 이름(전 22)
  static const double stripStatus = KioskType.caption; // 가전 상태(전 18)
}

/// 다음 루틴 카드 위 간격(위 안내·예보와 떨어지게).
const double _nextRunGap = KioskSpace.sm;

/// 다음 루틴 카드(평가 3차 10/18) — 오른쪽 칸 아래 끝, 가전 줄 바로 위. 첫 줄은 언제(크게) + '다음 루틴 · 자동 실행',
/// 둘째 줄은 무엇을(루틴 이름). 예전에는 예보 아래 회색 작은 줄이라 놓쳤다.
class _NextRunCard extends StatelessWidget {
  const _NextRunCard({super.key, required this.next});

  final KioskNextRun next;

  static const _pad = EdgeInsets.symmetric(horizontal: KioskSpace.sm, vertical: KioskSpace.xs);
  static const double _icon = 28;
  static const _timeStyle = TextStyle(
      fontSize: KioskType.status, height: 1.2, fontWeight: FontWeight.w800, color: Colors.white);
  static const _labelStyle =
      TextStyle(fontSize: KioskType.caption, height: 1.2, color: KioskColors.muted);
  static const _whatStyle = TextStyle(fontSize: KioskType.body, height: 1.25, color: Colors.white);

  /// 언제 — '오늘 오전 7시'(시계와 같은 오전/오후, 평가 4차 10/18).
  static String _time(KioskNextRun n) => n.when;

  /// 첫 줄 시각 옆 작은 글 — '다음 루틴 · 자동으로 해요'(자동 계열 이름은 하나로, 평가 4차 10/18). 무엇을(루틴 이름)은
  /// 둘째 줄에 따로(이름 뒤에 붙이면 끝말만 다음 줄로 떨어졌다).
  static String _caption(KioskNextRun n) => [
        '다음 루틴',
        if (n.quietSkip) '조용한 시간이라 건너뛰어요' else if (n.modeWord.isNotEmpty) n.modeWord,
      ].join(' · ');

  static double _textWidth(double width) =>
      width - _pad.horizontal - 2 - _icon - KioskSpace.sm;

  /// 폭 [width]에서 이 카드가 차지할 높이(테두리 포함). 첫 줄(시각 + 작은 글)이 넘치면 작은 글을 다음 줄로 잰다.
  static double heightFor(BuildContext context, KioskNextRun n, double width) {
    final w = _textWidth(width);
    final time = _textHeight(context, _time(n), _timeStyle, double.infinity);
    final timeW = _textWidthOf(context, _time(n), _timeStyle);
    final capW = _textWidthOf(context, _caption(n), _labelStyle);
    final head = timeW + KioskSpace.sm + capW <= w
        ? time
        : time + _textHeight(context, keepWords(_caption(n)), _labelStyle, w);
    final what = _textHeight(context, keepWords(n.name), _whatStyle, w);
    return _pad.vertical + 2 + head + what;
  }

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        label: next.line.replaceAll('\n', '. '),
        excludeSemantics: true,
        child: Container(
          padding: _pad,
          decoration: BoxDecoration(
            color: KioskColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: KioskColors.border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(Icons.schedule, size: _icon, color: Colors.white),
              const SizedBox(width: KioskSpace.sm),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.end,
                      spacing: KioskSpace.sm,
                      children: [
                        Text(_time(next),
                            key: const ValueKey('idle-next-run-time'),
                            maxLines: 1,
                            softWrap: false,
                            style: _timeStyle),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: KioskText(_caption(next), style: _labelStyle),
                        ),
                      ],
                    ),
                    // 어절 단위로 줄을 바꾼다(실패널에서 '공기청/정기'처럼 끊겼다).
                    KioskText(next.name,
                        textKey: const ValueKey('idle-next-run-what'), style: _whatStyle),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

double _textWidthOf(BuildContext context, String text, TextStyle style) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.merge(style)),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final w = tp.width;
  tp.dispose();
  return w;
}

/// 한 덩어리 글의 높이 — [Text]와 같은 기본 글꼴·배율로 잰다.
double _textHeight(BuildContext context, String text, TextStyle style, double maxWidth,
    {int? maxLines}) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.merge(style)),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: maxLines,
  )..layout(maxWidth: maxWidth < 0 ? 0 : maxWidth);
  final h = tp.height;
  tp.dispose();
  return h;
}

/// 위 줄의 방해 금지 자리. 꺼져 있으면 달 아이콘 단추(글자 없음 — 늘 보이는 글자는
/// 켜진 것으로 읽혔다), 켜져 있으면 채운 칩에 아이콘·"방해 금지"·남은 시간을 적는다
/// (색만으로 말하지 않는다). 둘 다 누르면 같은 방해 금지 선택이 열린다.
class _DndEntry extends StatelessWidget {
  const _DndEntry({super.key, required this.remaining, required this.onTap, this.quietUntil});

  /// 남은 시간 문구. null이면 꺼져 있다.
  final String? remaining;

  /// 매일 조용한 시간대의 끝 시각 — 있으면 "조용한 시간" / "07:00까지"(2026-10-14).
  final String? quietUntil;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final quiet = remaining == null ? quietUntil : null;
    final on = remaining != null || quiet != null;
    // '방해 금지'는 제안만 쉬는 줄 알았다(2026-10-15 검토) — '제안 쉬는 중' / 'N 남음'.
    final title = quiet != null ? '조용한 시간' : '쉬는 중';
    final sub = quiet != null ? '$quiet까지' : '$remaining 남음';
    return Semantics(
      button: true,
      label: quiet != null
          ? '조용한 시간, $quiet까지. 새 제안과 일반 안내 소리를 쉬어요'
          : on
              ? '잠시 쉬는 중, $remaining 남음. 끝내려면 누르세요'
              : '잠시 쉬기',
      child: ExcludeSemantics(
        child: Material(
          // 쉬는 중은 일상 상태 — 중립 회색 면(2026-10-16 디자인 규격 §1-4). 앰버 채움은 주요 행동 몫이다.
          color: on ? KioskColors.surface2 : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              // 터치 자리는 48px 이상(위 줄 높이 80에 맞춘다).
              constraints: const BoxConstraints(minWidth: 56, minHeight: 72),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: on ? 10 : 0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (!on)
                      // 꺼져 있으면 아이콘 아래 이름(UI 평가 3차 10/17) — 켜지면 오른쪽 두 줄이 같은 말을 한다.
                      const Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.pause_circle_outline, size: 28, color: KioskColors.muted),
                        KioskTopIconLabel('쉬기'),
                      ])
                    else
                      // 아이콘 규칙(평가 7차 10/18, 폰과 같이): 조용한 시간 = 달, 잠시 쉬기 = 일시정지.
                      Icon(quiet != null ? Icons.bedtime : Icons.pause_circle, size: 30, color: Colors.white),
                    if (on) ...[
                      const SizedBox(width: 6),
                      // 좁은 위 줄에 들어가도록 두 줄로 — "제안 쉬는 중" / 남은 시간.
                      // 큰 글씨에서도 같이 커진다(2026-10-15 B8 — 예전에는 배율을 막아 두었다). 위 줄 높이 안에 들도록 20.
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title,
                              maxLines: 1,
                              softWrap: false,
                              style: const TextStyle(
                                  fontSize: KioskType.body,
                                  height: 1.15,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white)),
                          Text(sub,
                              maxLines: 1,
                              softWrap: false,
                              style: const TextStyle(
                                  fontSize: KioskType.body,
                                  height: 1.15,
                                  color: Colors.white)),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 실내 공기 — '공기 좋아요' 한 줄(색 + 말)과 아래 작은 줄(공기청정기 전원·연습 값). 1~2 m에서 읽히게 앞 글은 굵게.
/// 숫자와 등급 출처는 LG 상세의 '자세히' 안에 둔다(2차 평가 10/18).
class _AirLine extends StatelessWidget {
  const _AirLine({super.key, required this.air, this.compact = false});
  final KioskAirReading air;

  /// 큰 글씨 — 아래 작은 줄을 뺀다(공기청정기 '켜짐'은 아래 가전 타일에도 있다).
  final bool compact;

  static const _headStyle =
      TextStyle(fontSize: KioskType.status, height: 1.2, fontWeight: FontWeight.w600);
  static const _subStyle = TextStyle(fontSize: KioskType.body, height: 1.3);

  /// 폭 [width]에서 이 줄이 차지할 높이(보통 글씨) — 평소 화면이 가전 타일 높이를 정할 때 쓴다.
  static double heightFor(BuildContext context, KioskAirReading air, double width) {
    final w = width - _Idle.airIcon - KioskSpace.sm;
    final word = kAirGradeSentences[air.grade] ?? air.gradeWord;
    var h = _textHeight(context, '공기 $word', _headStyle.copyWith(fontWeight: FontWeight.w800), w);
    if (air.sub.isNotEmpty) h += _textHeight(context, keepWords(air.sub.join('   ')), _subStyle, w);
    return h;
  }

  @override
  Widget build(BuildContext context) {
    // 공기는 한 줄 + 색(2차 평가 10/18) — '공기 보통이에요'. 숫자·'종합은 가전이 매긴 등급'은 LG 상세의 '자세히' 안.
    // 색만으로 말하지 않는다 — 등급 말이 늘 함께 있다.
    final color = airGradeColor(air.grade);
    final word = kAirGradeSentences[air.grade] ?? air.gradeWord;
    final sub = compact ? air.sub.where((d) => d == kPracticeNumbers).toList() : air.sub;
    return Semantics(
      container: true,
      label: [air.sentence, ...air.sub].join('. '),
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Icon(Icons.air, size: _Idle.airIcon, color: color),
          ),
          const SizedBox(width: KioskSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(children: [
                    const TextSpan(text: '공기 ', style: TextStyle(color: Colors.white)),
                    TextSpan(text: word,
                        style: TextStyle(color: color, fontWeight: FontWeight.w800)),
                  ]),
                  key: const ValueKey('idle-air-headline'),
                  style: _headStyle,
                ),
                if (sub.isNotEmpty)
                  KioskText(sub.join('   '),
                      textKey: const ValueKey('idle-air-detail'),
                      style: _subStyle.copyWith(color: KioskColors.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StripNotice extends StatelessWidget {
  const _StripNotice(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 누를 수 없는 안내다 — '+'는 단추로 읽혔다(2026-10-15 B5).
          const Icon(Icons.info_outline,
              size: 26, color: KioskColors.muted),
          const SizedBox(width: 10),
          // 큰 글씨에서는 줄을 바꾼다(넘치지 않게).
          Flexible(
            child: KioskText(text,
                style: const TextStyle(fontSize: _Idle.stripName, color: KioskColors.muted)),
          ),
        ],
      );
}

IconData _tipIcon(String icon) => switch (icon) {
      'rain' => Icons.umbrella_outlined,
      'snow' => Icons.ac_unit,
      'hot' => Icons.wb_sunny_outlined,
      'cold' => Icons.thermostat,
      // 루틴 안내(세탁 끝·복약, 2026-10-06) — 경고가 아니라 알림이다.
      'notice' => Icons.notifications_none_outlined,
      _ => Icons.error_outline,
    };

class _TipCard extends StatelessWidget {
  const _TipCard({super.key, required this.tip, this.compact = false});
  final AmbientTip tip;

  /// 큰 글씨 모드 — 여백·줄 간격을 줄여 같은 문장을 다 담는다.
  final bool compact;

  static const _maxLines = 4;
  static EdgeInsets _pad(bool compact) =>
      EdgeInsets.symmetric(horizontal: compact ? 10 : 14, vertical: compact ? 6 : 10);
  static double _gap(bool compact) => compact ? 8 : 10;
  static TextStyle _style(bool compact) =>
      TextStyle(fontSize: _Idle.tipText, height: compact ? 1.2 : 1.3);

  /// 폭 [width]에서 이 카드가 차지할 높이(테두리 1px 포함).
  static double heightFor(BuildContext context, AmbientTip tip, double width,
      {required bool compact}) {
    final pad = _pad(compact);
    final textWidth = width - pad.horizontal - 2 - _Idle.tipIcon - _gap(compact);
    final text = _textHeight(context, kioskLine(tip.text), _style(compact), textWidth,
        maxLines: _maxLines);
    return pad.vertical + 2 + (text > _Idle.tipIcon ? text : _Idle.tipIcon);
  }

  @override
  Widget build(BuildContext context) {
    // 확인이 필요한 가전·위험 소리는 노란 테 — 그 밖의 안내(날씨·루틴)는 테 없이
    // 차분한 면만(10/7). 테 자리(1px)는 늘 둬서 높이가 같다.
    final attention = tip.icon == 'attention';
    return Container(
      padding: _pad(compact),
      decoration: BoxDecoration(
        color: KioskColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: attention ? KioskColors.warning : Colors.transparent),
      ),
      child: Row(
        children: [
          Icon(_tipIcon(tip.icon),
              size: _Idle.tipIcon,
              // 일상 안내(날씨·루틴)는 중립 — 앰버는 확인 필요에만(2026-10-16 §1-4).
              color: attention ? KioskColors.warning : Colors.white),
          SizedBox(width: _gap(compact)),
          Expanded(
            // 서버 문장이 아주 길 때만 마지막 수단으로 말줄임한다. 어절 단위로 줄을 바꾼다("주/세요" 방지, 2026-10-16 §1-3).
            child: KioskText(
              kioskLine(tip.text),
              maxLines: _maxLines,
              overflow: TextOverflow.ellipsis,
              style: _style(compact).copyWith(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

/// 날짜 옆 바깥 날씨에 쓸 **지금** 칸(사용자 요청 10/18). 서버 예보(`hourly`)는 3시간 간격 칸이고 다음 경계부터 온다
/// (8:20이면 9·12·15·18시). 칸 시각이 지금 ±90분 안(3시간 칸이 대표하는 범위)이고 기온이 있을 때만 그 칸을 쓴다 —
/// 먼 칸의 값을 지금 날씨처럼 보이지 않는다. 없으면 null(아무것도 붙이지 않는다).
AmbientHour? outsideNowSlot(AmbientInfo? ambient, DateTime now) {
  if (ambient == null) return null;
  // 서버가 지금 칸을 주면 그것을 쓴다 — 3시간 칸만으로는 하루 절반쯤 비었다(10/18).
  if (ambient.now case final n? when n.temp != null) return n;
  final minutes = now.hour * 60 + now.minute;
  for (final h in ambient.hourly) {
    final at = h.slotHour;
    if (at == null || h.temp == null) continue;
    // 자정을 넘는 칸(23:00 → 0시)도 가깝게 잰다: 차이를 -720..720분으로.
    var diff = (at * 60 - minutes) % (24 * 60);
    if (diff > 12 * 60) diff -= 24 * 60;
    if (diff.abs() <= 90) return h;
  }
  return null;
}

String _weatherWord(String icon) => switch (icon) {
      'clear' => '맑음',
      'partly' => '구름 조금',
      'cloudy' => '흐림',
      'rain' => '비',
      'snow' => '눈',
      _ => '',
    };

/// 날짜 옆 '☁ 14°' — 아이콘은 예보 칸과 같은 모양(밤이면 달), 기온은 흰색 굵게(날짜보다 눈에 띄게).
class _OutsideNow extends StatelessWidget {
  const _OutsideNow({super.key, required this.slot});
  final AmbientHour slot;

  @override
  Widget build(BuildContext context) {
    final known = _hourIcon(slot.icon, label: slot.label) != Icons.remove;
    final word = _weatherWord(slot.icon);
    return Semantics(
      label: '바깥 ${word.isEmpty ? '' : '$word, '}${slot.temp}도',
      excludeSemantics: true,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (known) ...[
          _WeatherIcon(slot.icon, label: slot.label, size: KioskType.body + 5, color: Colors.white),
          const SizedBox(width: 6),
        ],
        Text('${slot.temp}°',
            maxLines: 1,
            softWrap: false,
            style: const TextStyle(
                fontSize: KioskType.body, fontWeight: FontWeight.w700, color: Colors.white)),
      ]),
    );
  }
}

/// 밤 시간(19~5시) 예보인가 — 칸 이름("0시")의 시각으로 가른다. 모르면 낮으로 본다.
bool _nightLabel(String label) {
  final m = RegExp(r'^(\d{1,2})시').firstMatch(label.trim());
  if (m == null) return false;
  final h = int.parse(m.group(1)!);
  return h >= 19 || h < 6;
}

/// 예보 아이콘 — 밤의 맑음·구름 조금은 해가 아니라 달(외부 평가 10/16 4차, 실패널 0시·3시에 해가 찍혔다).
IconData _hourIcon(String icon, {String label = ''}) => switch (icon) {
      'clear' when _nightLabel(label) => Icons.nightlight_outlined,
      'partly' when _nightLabel(label) => Icons.nights_stay_outlined,
      'clear' => Icons.wb_sunny_outlined,
      'partly' => Icons.wb_cloudy_outlined,
      'cloudy' => Icons.cloud_outlined,
      // 비는 [_WeatherIcon]이 비 오는 구름으로 그린다 — 물방울은 습도로 읽혔다(평가 10차 10/18). 여기 값은 '아는 날씨' 표시.
      'rain' => Icons.cloud_outlined,
      'snow' => Icons.ac_unit,
      _ => Icons.remove,
    };

/// 날씨 아이콘 하나 — 날짜 옆과 예보 칸이 같은 규칙(평가 10차 10/18). 비는 글꼴에 '비 오는 구름'이 없어 구름 + 빗줄기
/// 세 줄로 그린다(물방울은 습도, 우산은 '챙기세요' 안내로 읽혔다). 나머지는 [_hourIcon].
class _WeatherIcon extends StatelessWidget {
  const _WeatherIcon(this.icon, {this.label = '', required this.size, required this.color});
  final String icon;
  final String label;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (icon != 'rain') return Icon(_hourIcon(icon, label: label), size: size, color: color);
    return SizedBox(
      key: const ValueKey('weather-rain-cloud'),
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned(
          left: size * 0.05,
          top: -size * 0.1,
          child: Icon(Icons.cloud_outlined, size: size * 0.9, color: color),
        ),
        Positioned.fill(child: CustomPaint(painter: _RainPainter(color))),
      ]),
    );
  }
}

class _RainPainter extends CustomPainter {
  const _RainPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final paint = Paint()
      ..color = color
      ..strokeWidth = (w * 0.09).clamp(1.5, 4.0)
      ..strokeCap = StrokeCap.round;
    for (final x in const [0.32, 0.52, 0.72]) {
      canvas.drawLine(Offset(w * (x + 0.05), h * 0.7), Offset(w * (x - 0.04), h * 0.94), paint);
    }
  }

  @override
  bool shouldRepaint(_RainPainter old) => old.color != color;
}

class _Hours extends StatelessWidget {
  const _Hours({super.key, required this.hours, this.compact = false});
  final List<AmbientHour> hours;

  /// 안내 카드 아래에 함께 놓일 때 — 아이콘을 숫자 옆으로 붙여 한 줄을 줄인다.
  final bool compact;

  static TextStyle _labelStyle(bool compact) =>
      TextStyle(fontSize: _Idle.hourLabel, height: compact ? 1.2 : null);

  /// 예보 칸의 높이 — 가장 높은 칸 기준(FittedBox는 줄이기만 하므로 상한이다).
  static double heightFor(BuildContext context, List<AmbientHour> hours,
      {required bool compact}) {
    var max = 0.0;
    for (final h in hours) {
      final label =
          _textHeight(context, hourLabel12(h.label), _labelStyle(compact), double.infinity);
      final value = _textHeight(
          context,
          _valueOf(h),
          TextStyle(
              fontSize: _Idle.hourValue,
              height: compact ? 1.2 : null,
              fontWeight: h.precip ? FontWeight.w700 : FontWeight.w500),
          double.infinity);
      final cell = compact
          ? label + (value > _Idle.hourIcon ? value : _Idle.hourIcon)
          : label + 4 + _Idle.hourIcon + 4 + value;
      if (cell > max) max = cell;
    }
    return max;
  }

  /// 칸 값 — 기온은 '18°', 비·눈 칸은 '비 70%'·'눈 70%'(평가 4차 10/18: 기온 칸과 섞이면 '70%'가 무슨 숫자인지 몰랐다).
  static String _valueOf(AmbientHour h) => h.precip && h.pop != null
      ? '${h.icon == 'snow' ? '눈' : '비'} ${h.pop}%'
      : h.temp != null
          ? '${h.temp}°'
          : '';

  @override
  Widget build(BuildContext context) => Row(
        children: [
          for (final h in hours)
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 서버 칸 이름은 "15시"처럼 짧다. 더 긴 이름이 와도 잘리거나 겹치지
                  // 않게 칸 폭에 맞춰 줄인다(말줄임보다 낫다).
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    // 칸 이름은 오전/오후로(평가 4차 10/18 — 서버의 '15시'는 24시라 시계·루틴과 달랐다).
                    child: Text(hourLabel12(h.label),
                        maxLines: 1,
                        softWrap: false,
                        style: _labelStyle(compact)
                            .copyWith(color: KioskColors.muted)),
                  ),
                  if (compact)
                    // 아이콘과 숫자를 한 줄에 — 안내 카드 아래 남은 높이에 맞춘다. 비·눈 칸은 글자('비 70%')가 말하므로
                    // 아이콘을 빼 옆 칸과 붙지 않게 한다(평가 4차 10/18).
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (!(h.precip && h.pop != null)) ...[
                          _WeatherIcon(h.icon,
                              label: h.label,
                              size: _Idle.hourIcon,
                              color: KioskColors.muted),
                          const SizedBox(width: 2),
                        ],
                        _ValueText(h: h, text: _valueOf(h), height: 1.2),
                      ]),
                    )
                  else ...[
                    const SizedBox(height: 4),
                    _WeatherIcon(h.icon,
                        label: h.label,
                        size: _Idle.hourIcon,
                        color: h.precip ? Colors.white : KioskColors.muted),
                    const SizedBox(height: 4),
                    _ValueText(h: h, text: _valueOf(h)),
                  ],
                ],
              ),
            ),
        ],
      );
}

/// 비·눈 칸은 강수확률을, 나머지는 기온을 — 색만이 아니라 숫자로.
class _ValueText extends StatelessWidget {
  const _ValueText({required this.h, required this.text, this.height});
  final AmbientHour h;
  final String text;
  final double? height;

  @override
  Widget build(BuildContext context) => Text(
        text,
        maxLines: 1,
        softWrap: false,
        style: TextStyle(
          fontSize: _Idle.hourValue,
          height: height,
          fontWeight: h.precip ? FontWeight.w700 : FontWeight.w500,
          color: h.precip ? Colors.white : KioskColors.muted,
        ),
      );
}

/// 위쪽 칩·메뉴가 여는 큰 창(메뉴·연결 목록)을 들고 있는 껍데기(화면 구조 개편 10/18).
/// 창은 캔버스 안에 그린다(확대·가장자리 여백을 그대로 따른다).
enum _Sheet { none, menu, connections }

class _IdleSheets {
  const _IdleSheets(this.openMenu, this.openConnections);
  final VoidCallback openMenu;
  final VoidCallback openConnections;
}

class _IdleSheetHost extends StatefulWidget {
  const _IdleSheetHost({required this.view, required this.builder});

  final KioskIdleView view;
  final Widget Function(_IdleSheets sheets) builder;

  @override
  State<_IdleSheetHost> createState() => _IdleSheetHostState();
}

class _IdleSheetHostState extends State<_IdleSheetHost> {
  _Sheet _sheet = _Sheet.none;

  void _close() => setState(() => _sheet = _Sheet.none);

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    final body = widget.builder(_IdleSheets(
      () => setState(() => _sheet = _Sheet.menu),
      () => setState(() => _sheet = _Sheet.connections),
    ));
    if (_sheet == _Sheet.none) return body;
    final dnd = v.dndUntil != null && v.dndUntil!.isAfter(v.now) ? v.dndUntil : null;
    final restSub = dnd != null
        ? '쉬는 중이에요. ${v._dndRemaining(dnd)} 남음'
        : v.quietUntil != null
            ? '조용한 시간이에요. ${spokenHhmm(v.quietUntil!)}까지'
            // 잠시 쉬기 창과 같은 말(평가 8차 10/18) — 새로 켜는 잠시 쉬기는 새 제안과 자동으로 하는 일을 함께 쉰다.
            : '새 제안과 자동으로 하는 일을 잠시 쉬어요';
    return Stack(children: [
      body,
      Positioned.fill(
        child: _sheet == _Sheet.menu
            ? KioskIdleSheet(
                title: '메뉴',
                onClose: _close,
                children: [
                  KioskSheetRow(
                    key: const ValueKey('dnd-entry'),
                    // 잠시 쉬기 = 일시정지(평가 7차 10/18 — 달은 폰에서 조용한 시간이다).
                    icon: dnd != null ? Icons.pause_circle : Icons.pause_circle_outline,
                    label: '잠시 쉬기',
                    sub: restSub,
                    onTap: () {
                      _close();
                      v.onDndGesture();
                    },
                  ),
                  KioskSheetRow(
                    key: const ValueKey('settings-entry'),
                    icon: Icons.settings_outlined,
                    label: '설정',
                    sub: '큰 글씨, 음성 안내, 폰 연결',
                    semanticsLabel: '설정',
                    onTap: () {
                      _close();
                      v.onSettingsGesture?.call();
                    },
                  ),
                ],
              )
            : KioskIdleSheet(
                title: '연결',
                onClose: _close,
                children: connectionRows(connectionsForDisplay(v.connections, connected: v.connected), (item) {
                  _close();
                  v.onOpenConnection(item);
                }),
              ),
      ),
    ]);
  }
}
