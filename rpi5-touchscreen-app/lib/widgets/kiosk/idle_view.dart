import 'package:flutter/material.dart';
import 'estop_banner.dart';

import '../../models/ambient.dart';
import '../../models/appliance.dart';
import '../../models/josa.dart';
import '../../models/kiosk_time.dart';
import '../../models/thinq.dart';
import '../../theme/kiosk_colors.dart';
import 'appliance_strip.dart';
import 'connection_status.dart';
import 'dnd_overlay.dart' show kDndCarriedScopeText, kDndName, kDndScopeText;
import 'help_guide.dart';
import 'idle_featured.dart';
import 'kiosk_tab_bar.dart';
import 'idle_side_rows.dart';
import 'idle_top.dart';
import '../../theme/kiosk_tokens.dart';
import 'kiosk_canvas.dart';
import 'kiosk_modal.dart';
import 'kiosk_text.dart';
import 'thinq_panel.dart' show airGradeColor;

/// 평소 화면(UI 확정 2026-09-30 §3-1) — 집에 붙은 시계처럼.
///
/// - 위 줄: 왼쪽 날짜, 설정 진입, 방해 금지, 오른쪽 연결 아이콘 세 개(문제면 "!").
///   방해 금지는 꺼져 있으면 달 아이콘 단추뿐이고(글자가 늘 보이면 켜진 것으로
///   읽혔다, 10/5), 켜져 있으면 채운 칩에 "방해 금지"와 남은 시간을 적는다.
/// - 가운데 왼쪽: 큰 시계와 실내 온도·습도, 공기가 나쁠 때만 공기 한 줄, 다음 루틴 한두 줄 + '오늘은 건너뛰기'(10/18).
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
    this.dndScope,
    this.quietUntil,
    this.temperature,
    this.humidity,
    this.air,
    this.nextRun,
    this.nextRunBusy = false,
    this.nextRunNotice,
    this.onToggleNextRunSkip,
    required this.onSelectAppliance,
    required this.onOpenConnection,
    required this.onDndGesture,
    this.onSettingsGesture,
    this.onEstopGuide,
    this.quietDim = false,
    this.onTouch,
    this.routines,
    this.onRoutine,
  });

  /// 저장된 동작(루틴) — 맨 앞 하나를 '무엇을 할까요?' 카드로 세운다(시안 B 10/24). 누르면 [onRoutine] — 내 가전 화면의
  /// 루틴 칸과 같은 길(서버가 확인 카드를 만들고 그 카드의 '시작'이 승인). 둘 중 하나라도 없으면 카드가 없다.
  final List<KioskRoutine>? routines;
  final ValueChanged<KioskRoutine>? onRoutine;

  /// 조용한 시간이라 어둡게(사용자 결정 10/18) — 시계·다음 루틴·문제 표시만 남기고 예보·인사말·온습도·가전 줄을 접고,
  /// 화면 전체에 어두운 막을 얹는다. 막을 누르면 [onTouch]만 불린다(그 아래 단추는 눌리지 않는다 — 깨우는 손길).
  /// 처음 화면에만 쓴다 — 실행·정지 대기·결과·제안·비상 화면은 kiosk_screen이 어둡게 하지 않는다(안전).
  final bool quietDim;

  /// 화면을 만졌다(어디든) — kiosk_screen이 조용한 시간에 잠시(30초) 평소 밝기로 돌린다.
  final VoidCallback? onTouch;

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

  /// 방해 금지 범위(서버 `dnd_scope`) — `suggestions_only`면 새 제안만 쉰다고 말한다.
  final String? dndScope;

  /// 매일 조용한 시간대 안이면 끝 시각("07:00", 2026-10-14). 방해 금지가 켜져 있으면 그쪽이 먼저 보인다.
  final String? quietUntil;
  final double? temperature;
  final double? humidity;

  /// 공기청정기 센서 공기질(GET /thinq/air, 2026-10-16 — 서버 기억, 클라우드 호출 없음). null이면(모름·오래됨·없음) 줄을 두지 않는다.
  /// 줄은 **공기가 나쁠 때(나쁨·매우 나쁨)만** 보인다(사용자 결정 10/18) — 평소에는 그 자리에 다음 루틴을 적는다.
  final KioskAirReading? air;

  /// 다음 시각 루틴(GET /routines/next, 외부 평가 10/16 2차 k01). null이면 줄을 두지 않는다.
  /// 시계 아래에 담담한 한두 줄 + '오늘은 건너뛰기'(사용자 결정 10/18 — 오른쪽 큰 카드는 없앴다).
  final KioskNextRun? nextRun;

  /// '오늘은 건너뛰기'·'되돌리기'를 보내는 중 — 단추를 막는다(같은 요청 두 번 금지).
  final bool nextRunBusy;

  /// 건너뛰기 실패 안내 한 줄(서버 detail 그대로 또는 짧은 말). null이면 없다.
  final String? nextRunNotice;

  /// 건너뛰기·되돌리기 단추. null이면 단추를 두지 않는다.
  final ValueChanged<KioskNextRun>? onToggleNextRunSkip;
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

  /// 실내 온습도 — 날짜 옆 두 조각(온도계 '24°' · 물방울 '57%', 사용자 요청 10/20). 실측일 때만 값이 온다
  /// (kiosk_screen이 모의면 null을 넘긴다). 온도가 없으면 아무것도 두지 않는다.
  _IndoorEnv? get _indoor {
    final t = temperature;
    if (t == null) return null;
    return _IndoorEnv(temperature: t, humidity: humidity);
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
    final list = appliances;
    // 큰 글씨 모드(kiosk_screen이 1.22배 textScaler를 얹는다)에서는 같은 800x480 캔버스에 글자만 커지므로, 자르지 않고
    // **덜 보인다**: 가전은 한 장에 2개, 오른쪽 칸을 조금 넓힌다.
    final large = MediaQuery.textScalerOf(context).scale(10) > 10.5;
    final indoor = _indoor;
    final badAir = airIfBad(air);
    // 공기가 나쁘면 할 일 한 줄(평가 14차 10/18) — 그 공기청정기가 가전 줄에 있을 때만(없으면 지어내지 않는다).
    final airTarget = badAir == null ? null : list?.where((a) => a.id == badAir.applianceId).firstOrNull;
    final airAction = airTarget == null ? null : airActionLabel(badAir!, airTarget.displayName);
    final next = nextRun;
    final rawTip = (amb?.tip != null && amb!.tip!.text.isNotEmpty) ? amb.tip : null;
    // 날씨 안내는 '바깥 날씨' 줄이, 그 밖의 안내(확인 필요 가전·약 드실 시간 등)는 오른쪽 칸 맨 위 '알림' 줄이 말한다
    // (시안 B 10/24 — 예전에는 연결 문제 띠 둘째 줄에 묶었다. 띠는 이제 한 줄이라 다른 것을 밀어내지 않는다).
    final weatherTip = rawTip != null && isWeatherTip(rawTip) ? rawTip : null;
    final noticeTip = rawTip != null && !isWeatherTip(rawTip) ? rawTip : null;
    final dnd = dndUntil != null && dndUntil!.isAfter(now) ? dndUntil : null;
    // 본체에 닿지 않으면 지난 연결 목록을 믿지 않는다(평가 7차 10/18 — 끊겼는데 칩이 '모두 정상').
    final connections = connectionsForDisplay(this.connections, connected: connected);
    // 누름 장치 연결이 끊겼나(평가 3차 10/18) — 끊기면 누름 장치가 누르는 가전 타일은 '지금은 쓸 수 없어요' 표시.
    final pressItem = connections.where((c) => c.id == 'press').firstOrNull;
    final pressDown = pressItem?.state == 'error';
    // 비상 버튼이 눌려 있나(평가 4차 10/18) — 위 빨간 띠와 같은 사실을 칩·타일도 말한다. 걸려 있는 동안은 실행이
    // 거절되므로 누름 장치로 누르는 가전은 누름 장치 끊김과 같이 '지금은 쓸 수 없어요' 표시.
    final estop = KioskEstopScope.shownOf(context);
    // 지금 쓸 수 없는 가전(누름 장치 끊김·비상 버튼) — 가전 줄 '!'와 '무엇을 할까요?' 카드가 같이 쓴다.
    final unavailable = <String>{
      if ((pressDown || estop) && list != null)
        for (final a in list)
          if (a.usesPressDevice) a.id,
    };
    final onRoutine = this.onRoutine;
    // 지금 할 수 있는 동작을 먼저 고른다(첫 사용 평가 10/24 — 누름 장치가 끊겼는데 전자레인지 동작을 '실행하기'로 내걸었다).
    // 가늠은 가전 줄 '!'와 같은 판정([kioskTileIssue])이다. 자리가 모자라면 아래에서 접는다(가전 줄이 먼저다).
    final featured = quietDim || onRoutine == null
        ? null
        : KioskFeaturedAction.pick(routines, list,
            issueOf: (a) => kioskTileIssue(a, unavailable: unavailable.contains(a.id), unavailableByEstop: estop));
    // 가전은 한 장에 3개(시안 B 10/24 — 폰 홈처럼 큰 그림 칸), 큰 글씨는 2개. 더 많으면 좁은 장 넘김.
    final perPage = large ? 2 : 3;
    final pager = list == null || list.length > perPage;
    final (_, connProblem, _) = connectionSummary(connections);
    // 가전 타일 누름 — 못 쓰는 가전은 조작판 대신 이유를 연다(비상 버튼이면 풀기 안내, 누름 장치 끊김이면 그 연결 창).
    // 막힌 '무엇을 할까요?' 카드의 '해결 방법 보기'도 같은 길이다(첫 사용 평가 2차 10/24).
    void selectTile(ApplianceMap a) {
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
    }

    Widget statusChip(_IdleSheets sheets) => KioskIdleStatusChip(
          compact: true,
          items: connections,
          // 누름 장치가 끊겨 '지금은 쓸 수 없어요' 표시인 가전 수(아래 타일과 같은 규칙 — 누름 장치가 누르는 가전).
          pressImpact: pressDown && list != null ? list.where((a) => a.usesPressDevice).length : null,
          onTap: () {
            // 문제가 하나면 그 연결 창을 바로, 그 밖에는 연결 목록 창. 비상 버튼 띠 아래에서는 칩이 연결 문제만 말한다
            // (평가 14차 10/18) — 풀기 안내는 띠의 '풀기 안내'·못 쓰는 가전 타일이 연다.
            final (_, _, direct) = connectionSummary(connections);
            direct != null ? onOpenConnection(direct) : sheets.openConnections();
          },
        );

    // 위 줄(시안 B 10/24): 시계 '오후 3:12' · 날짜와 실내 온습도 · (쉬는 중 칩) · (확인 중 칩) · 메뉴(톱니바퀴).
    // 상태 칩·메뉴는 오른쪽에 붙여 재므로 쉬는 중 칩이 켜져도 메뉴 자리가 바뀌지 않는다(UI 평가 4차 10/17).
    // 조용한 시간 화면은 큰 시계를 따로 그리므로 위 줄 시계를 뺀다([withClock]).
    Widget topRow(_IdleSheets sheets, {bool withClock = true}) =>
        Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
              height: _Idle.topRow,
              child: LayoutBuilder(builder: (context, top) {
                final topWidth = top.maxWidth;
                final date = Text(_dateStr,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                        fontSize: KioskType.caption, height: 1.2, fontWeight: FontWeight.w600, color: KioskColors.ink));
                return Row(children: [
                  if (withClock) ...[
                    _BarClock(ampm: ampmOf(now.hour), digits: _clock),
                    const SizedBox(width: KioskSpace.md),
                  ],
                  // 날짜 아래 실내 온습도(시안 B) — 자리가 모자라면 통째로 조금 줄인다(잘리지 않게).
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [date, if (indoor != null) indoor],
                        ),
                      ),
                    ),
                  ),
                  if (dnd != null || quietUntil != null) ...[
                    _DndEntry(
                        key: const ValueKey('dnd-chip'),
                        remaining: dnd == null ? null : _dndRemaining(dnd),
                        quietUntil: dnd == null && quietUntil != null ? spokenHhmm(quietUntil!) : null,
                        onTap: onDndGesture),
                    const SizedBox(width: KioskSpace.sm),
                  ],
                  // 쉬는 중 칩 + 확인 중 칩 + 큰 글씨가 겹치면 위 줄이 모자란다 — 칩은 잘리지 않고 통째로 조금 줄어든다.
                  if (!connProblem)
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: topWidth * (large ? 0.36 : 0.4)),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: statusChip(sheets),
                      ),
                    ),
                  const SizedBox(width: KioskSpace.xs),
                  KioskIdleMenuButton(onTap: sheets.openMenu),
                ]);
              })),
          // 연결 문제는 위 줄 아래 **한 줄 띠**(시안 B 10/24 — 높이 고정, 아래 칸을 밀어내지 않는다).
          if (connProblem) ...[
            statusChip(sheets),
            const SizedBox(height: KioskSpace.xs),
          ],
        ]);

    // 오른쪽 칸 줄들(시안 B 10/24) — 값이 있는 줄만. 순서: 알림 · 다음 자동 실행 · 바깥 날씨 · 공기질.
    final nowSlot = outsideNowSlot(amb, now);
    // 서버에 '지금' 칸이 없으면(밤 11시처럼 지난 정시 칸이 없을 때 — 10/24 실패널에서 날씨 줄이 통째로 사라졌다) 가장 가까운
    // 예보 칸을 **그 시각을 붙여** 보인다. '지금'으로 꾸미지 않는다.
    final shownWeather = nowSlot ??
        amb?.hourly.where((h) => h.temp != null).firstOrNull;
    final rainSlot = forecastSlots(amb, now)
        .where((s) => !s.isNow && (s.hour.precip || s.hour.icon == 'rain' || s.hour.icon == 'snow' || (s.hour.pop ?? 0) >= 60))
        .firstOrNull;
    final weatherAdvice = weatherTip != null
        ? kioskLine(weatherTip.text)
        : rainSlot == null
            ? null
            : [rainSlot.label, _rainWord(rainSlot.hour)].join(' ');
    // 날씨가 아닌 안내(확인 필요 가전·약 드실 시간 등) — 가전 줄 아래 빈자리가 넉넉하면 그 아래(가전과 이어지는 말),
    // 모자라면 오른쪽 칸 맨 위. 어느 쪽이든 한 곳에만.
    final notice = noticeTip == null
        ? null
        : KioskSideRow(
            key: const ValueKey('ambient-tip'),
            label: noticeTip.icon == 'attention' ? '주의' : '알림',
            child: _NoticeLine(tip: noticeTip),
          );
    final sideRows = <Widget>[
      if (next != null)
        KioskSideRow(
          child: _NextRunLine(
              key: const ValueKey('idle-next-run'),
              next: next,
              stacked: true,
              busy: nextRunBusy,
              notice: nextRunNotice,
              onToggle: onToggleNextRunSkip),
        ),
      if (shownWeather != null || weatherAdvice != null)
        KioskSideRow(
          key: const ValueKey('idle-weather'),
          label: '바깥 날씨',
          child: _WeatherLine(
            now: shownWeather,
            at: nowSlot == null && shownWeather != null ? hourLabel12(shownWeather.label) : null,
            night: _nightHour(nowSlot == null && shownWeather != null ? (shownWeather.slotHour ?? now.hour) : now.hour),
            advice: weatherAdvice,
            adviceIsTip: weatherTip != null,
          ),
        ),
      if (air case final a?)
        KioskSideRow(
          label: '공기질',
          inline: true,
          child: _AirRow(
            key: const ValueKey('idle-air'),
            air: a,
            action: a == badAir ? airAction : null,
            onAction: a == badAir && airTarget != null ? () => onSelectAppliance(airTarget) : null,
          ),
        ),
    ];

    final Widget host = _IdleSheetHost(view: this, builder: (sheets) => quietDim
        ? _QuietIdle(
            view: this,
            topRow: topRow(sheets, withClock: false),
            clock: _clock,
            large: large,
            air: badAir)
        : ColoredBox(
      color: KioskColors.bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(_Idle.side, 4, _Idle.side, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          topRow(sheets),
          const SizedBox(height: 4),
          Expanded(child: LayoutBuilder(builder: (context, body) {
            final sideWidth = large ? _Idle.sideLarge : _Idle.sideWidth;
            final leftWidth = body.maxWidth - sideWidth - _Idle.columnGap;
            // '무엇을 할까요?' 카드는 가전 줄이 제 하한을 지킬 때만(위에 띠·지난 일 줄이 겹치면 접는다 — 가전 줄이 먼저다).
            final stripMin = large ? _Idle.stripLargeMin : _Idle.stripTightMin;
            final featuredHeight = KioskFeaturedAction.heightFor(context) + _Idle.featuredGap;
            final showFeatured = featured != null && body.maxHeight - featuredHeight >= stripMin;
            final stripRoom = body.maxHeight - (showFeatured ? featuredHeight : 0);
            final stripMax = large ? _Idle.stripLarge : _Idle.stripMax;
            var strip = (stripRoom < stripMax ? stripRoom : stripMax).clamp(0.0, stripMax).toDouble();
            // 안내를 가전 줄 아래에 둘 수 있나 — 가전 줄을 하한까지 낮춰서라도 들어가면 거기.
            final noticeHeight = noticeTip == null ? 0.0 : _NoticeLine.heightFor(context, noticeTip, leftWidth) + _Idle.featuredGap;
            var noticeLeft = false;
            if (noticeTip != null && stripRoom - stripMin >= noticeHeight) {
              noticeLeft = true;
              if (stripRoom - strip < noticeHeight) strip = stripRoom - noticeHeight;
            }
            final tileHeight = strip - _Idle.stripPad;
            final left = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (showFeatured) ...[
                KioskFeaturedAction(
                  routine: featured.$1,
                  appliance: featured.$2,
                  sizeLabel: featured.$1.sizeLabelWith({for (final a in list!) a.id: a.displayName}),
                  blockedReason: featured.$3,
                  onRun: () => onRoutine!(featured.$1),
                  // 막힌 가전의 안내(코드 검토 10/24) — 루틴 첫 가전은 쓸 수 있을 수 있다.
                  onHelp: () => selectTile(featured.$4 ?? featured.$2),
                  // 연결 문제 띠가 이미 '해결 방법 보기'를 보인다 — 카드는 되풀이하지 않는다(첫 사용 평가 4차 10/24).
                  helpInBanner: connProblem,
                ),
                const SizedBox(height: _Idle.featuredGap),
              ],
              // 가전 줄은 왼쪽 선에서 시작한다(평가 3차 10/18). 타일 폭은 남은 폭을 장 넘김 칸과 나눠 잰다.
              SizedBox(
                  height: strip,
                  child: LayoutBuilder(builder: (context, box) {
                    final itemWidth =
                        (box.maxWidth - (pager ? KioskApplianceStrip.compactPagerWidth : 0)) / perPage;
                    return Align(
                        alignment: list == null || list.isEmpty ? Alignment.centerLeft : Alignment.topLeft,
                        child: SingleChildScrollView(
                            child: list == null
                                ? const _StripNotice('본체와 연결되면 가전이 보여요')
                                : list.isEmpty
                                    ? const _StripNotice('휴대폰 앱에서 가전을 추가해 주세요')
                                    : KioskApplianceStrip(
                                        appliances: list,
                                        running: estop ? const {} : running,
                                        attention: estop ? {...attention, ...running} : attention,
                                        on: estop ? const {} : on,
                                        off: estop ? const {} : off,
                                        unavailable: unavailable,
                                        // 비상 버튼이면 띠가 빨강, 누름 장치 끊김이면 회색(평가 6차 10/18).
                                        unavailableByEstop: estop,
                                        // 못 쓰는 가전은 조작판 대신 이유를 연다 — 비상 버튼이면 풀기 안내, 누름 장치 끊김이면 그 연결 창.
                                        onSelect: selectTile,
                                        perPage: perPage,
                                        reservePager: pager,
                                        compactPager: true,
                                        itemWidth: itemWidth,
                                        labelSize: _Idle.stripName,
                                        statusSize: _Idle.stripStatus,
                                        iconBox: _Idle.tileArt,
                                        tileHeight: tileHeight)));
                  })),
            ]);
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                  width: leftWidth,
                  child: noticeLeft
                      ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          left,
                          const SizedBox(height: _Idle.featuredGap),
                          notice!,
                        ])
                      : left),
              const SizedBox(width: _Idle.columnGap),
              // 오른쪽 칸 — 칸 없이 줄로만. 넘치면(아주 드문 겹침) 자르지 않고 스크롤.
              SizedBox(
                width: sideWidth,
                height: body.maxHeight,
                child: SingleChildScrollView(
                    child: KioskSideColumn(rows: [if (notice != null && !noticeLeft) notice, ...sideRows])),
              ),
            ]);
          })),
        ]),
      ),
    ));
    final touch = onTouch;
    if (touch == null) return host;
    // 화면 어디를 만져도 알린다(단추 동작은 그대로 지나간다).
    return Listener(behavior: HitTestBehavior.translucent, onPointerDown: (_) => touch(), child: host);
  }

  /// 조용한 시간 화면에서 시계 아래(나쁜 공기·다음 루틴)가 [width] 폭에서 차지할 높이 — 시계 크기를 정하는 데만 쓴다.
  static double _leftRest(BuildContext context, double width,
      {KioskAirReading? air, KioskNextRun? next,
      ValueChanged<KioskNextRun>? onToggle, String? notice}) {
    var h = 0.0;
    if (air != null) h += _Idle.airGap + _AirLine.heightFor(context, air, width);
    if (next != null) {
      h += _Idle.nextGap +
          _NextRunLine.heightFor(context, next, width, withButton: onToggle != null, notice: notice);
    }
    return h;
  }
}

/// 비·눈 칸의 강수확률 말('비 70%'). 확률을 모르면 '비'.
String _rainWord(AmbientHour h) {
  final what = h.icon == 'snow' ? '눈' : '비';
  return h.pop != null ? '$what ${h.pop}%' : what;
}

/// 위 줄 시계(시안 B 10/24) — '오후 3:12' 한 덩어리, 굵게. 화면에서 가장 큰 글이 아니라 위 줄 안에 든다(가전·할 일이 먼저).
class _BarClock extends StatelessWidget {
  const _BarClock({required this.ampm, required this.digits});

  final String ampm;
  final String digits;

  static const double size = 34;

  @override
  Widget build(BuildContext context) => Row(
        key: const ValueKey('idle-clock'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(ampm,
              maxLines: 1,
              softWrap: false,
              // 이미 크다 — 큰 글씨 배율을 얹지 않는다(위 줄 높이 안에 든다).
              textScaler: TextScaler.noScaling,
              style: TextStyle(fontSize: size * 0.82, height: 1.1, fontWeight: FontWeight.w700, color: KioskColors.ink)),
          const SizedBox(width: 6),
          Text(digits,
              maxLines: 1,
              softWrap: false,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                  fontSize: size,
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                  color: KioskColors.ink,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      );
}

/// '알림'·'확인 필요' 줄(오른쪽 칸 맨 위) — 날씨가 아닌 안내 한 덩어리. 확인 필요 가전은 앰버 아이콘.
class _NoticeLine extends StatelessWidget {
  const _NoticeLine({required this.tip});

  final AmbientTip tip;

  static const int _maxLines = 4;
  static const double _icon = 22;
  static const double _gap = 6;
  static String _drawn(AmbientTip tip) => keepWords(keepPhrases(kioskLine(tip.text)));
  static TextStyle get _style => KioskSideRow.valueStyle.copyWith(fontWeight: FontWeight.w600);

  /// 폭 [width]에서 머리말까지 더한 높이 — 처음 화면이 가전 줄 아래에 둘지 정한다.
  static double heightFor(BuildContext context, AmbientTip tip, double width) =>
      _textHeight(context, '알림', KioskSideRow.labelStyle, double.infinity) +
      2 +
      _textHeight(context, _drawn(tip), _style, width - _icon - _gap, maxLines: _maxLines);

  @override
  Widget build(BuildContext context) {
    final attention = tip.icon == 'attention';
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Icon(_tipIcon(tip.icon), size: _icon, color: attention ? KioskColors.warning : KioskColors.ink),
      ),
      const SizedBox(width: _gap),
      Expanded(
        child: Text.rich(
          TextSpan(text: _drawn(tip), semanticsLabel: kioskLine(tip.text)),
          key: const ValueKey('ambient-tip-text'),
          maxLines: _maxLines,
          overflow: TextOverflow.ellipsis,
          style: _style,
        ),
      ),
    ]);
  }
}

/// '바깥 날씨' 줄 — 지금 칸(서버 '지금'만, [outsideNowSlot])의 아이콘·기온·날씨 말, 아래 작은 줄은 날씨 안내 또는 가까운 비 소식.
class _WeatherLine extends StatelessWidget {
  const _WeatherLine({this.now, this.at, required this.night, this.advice, this.adviceIsTip = false});

  final AmbientHour? now;

  /// [now]가 '지금'이 아니라 예보 칸이면 그 시각('오전 12시') — 값 뒤에 '· 오전 12시 예보'로 붙인다.
  final String? at;
  final bool night;
  final String? advice;

  /// 아래 줄이 서버 날씨 안내(할 일이 담긴 문장)인가 — 그러면 흰 글자, 비 소식이면 회색.
  final bool adviceIsTip;

  @override
  Widget build(BuildContext context) {
    final n = now;
    final word = n == null ? '' : _weatherWord(n.icon);
    final spoken = [
      '바깥 날씨',
      if (at != null) '$at 예보',
      if (n?.temp != null) '${n!.temp}도',
      if (word.isNotEmpty) word,
      if (advice case final a?) a,
    ].join(', ');
    return Semantics(
      container: true,
      label: spoken,
      excludeSemantics: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (n != null)
          Row(key: ValueKey(at == null ? 'idle-weather-now' : 'idle-weather-forecast'), children: [
            _WeatherIcon(n.icon, night: night, size: 24, color: KioskColors.ink),
            const SizedBox(width: 6),
            Flexible(
              child: Text.rich(
                TextSpan(children: [
                  if (n.temp != null) TextSpan(text: '${n.temp}°'),
                  if (word.isNotEmpty)
                    TextSpan(text: '${n.temp != null ? ' ' : ''}$word', style: const TextStyle(fontWeight: FontWeight.w500)),
                  if (at != null)
                    TextSpan(text: ' · $at 예보', style: KioskSideRow.smallStyle.copyWith(color: KioskColors.muted)),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: KioskSideRow.valueStyle,
              ),
            ),
          ]),
        if (advice case final a?)
          Text.rich(
            TextSpan(text: keepWords(keepPhrases(a)), semanticsLabel: a),
            key: const ValueKey('idle-weather-advice'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: KioskSideRow.smallStyle.copyWith(
                color: adviceIsTip ? KioskColors.ink : KioskColors.muted,
                fontWeight: adviceIsTip ? FontWeight.w600 : null),
          ),
      ]),
    );
  }
}

/// '공기질' 줄 — 가전이 매긴 등급 말(색 + 말) · 초미세먼지 값(알 때만) · 연습 값 안내. 나쁘면 할 일 한 줄을 붙이고 줄 전체를
/// 누르면 그 공기청정기 화면(평가 14·15차 10/18과 같은 길 — 바꾸는 것은 그 화면에서 사람이 고른다).
class _AirRow extends StatelessWidget {
  const _AirRow({super.key, required this.air, this.action, this.onAction});

  final KioskAirReading air;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final color = airGradeColor(air.grade);
    // 값은 가전이 매긴 등급 말(명사형 '좋음'·'나쁨') + 같은 색 아이콘(색만으로 말하지 않는다). 먼지 숫자는 두지 않는다 —
    // 종합 등급과 숫자가 엇갈려 읽혔다(외부 평가 10/16, 2차 평가 10/18). 숫자는 LG 상세의 '미세먼지 보기' 안.
    final line = Semantics(
      container: true,
      label: [air.sentence, if (air.mock) kPracticeNumbers].join('. '),
      excludeSemantics: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Icon(Icons.air, size: 24, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: keepWords(air.gradeWord),
                    semanticsLabel: air.gradeWord,
                    style: TextStyle(color: color, fontWeight: FontWeight.w800)),
              ]),
              key: const ValueKey('idle-air-headline'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: KioskSideRow.valueStyle,
            ),
          ),
        ]),
        if (air.mock)
          Text(kPracticeNumbers,
              key: const ValueKey('idle-air-detail'), maxLines: 2, overflow: TextOverflow.ellipsis, style: KioskSideRow.smallStyle),
      ]),
    );
    final act = action;
    if (act == null || onAction == null) return line;
    return Semantics(
      button: true,
      label: act,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: const ValueKey('idle-air-tap'),
          onTap: onAction,
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              line,
              Padding(
                key: const ValueKey('idle-air-action'),
                // 등급 말과 같은 글 선(아이콘 24 + 사이 6).
                padding: const EdgeInsets.only(top: 2, left: 30),
                child: ExcludeSemantics(
                    child: Text(act, style: _NextRunLine._buttonStyle.copyWith(color: KioskColors.muted))),
              ),
            ]),
          ),
        ),
      ),
    );
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
                  style: TextStyle(
                      fontSize: KioskType.status, height: 1, color: KioskColors.muted)),
              const SizedBox(width: KioskSpace.xs),
              Text(digits,
                  maxLines: 1,
                  softWrap: false,
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                      fontSize: size,
                      height: 1,
                      color: KioskColors.ink,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
        ),
      );
}

/// 평소 화면 치수(캔버스 800x480 기준 논리 px, 1920x1080 실패널에서는 2.05배). 시안 B(10/24)는 960x540 반쪽 그림이라
/// 그림 px ≈ 캔버스 px로 옮겼다(글자는 키오스크 글자 단계를 따른다 — 그림보다 조금 크다).
///
/// 글자 하한: 고령층 키오스크 지침의 14pt(사용자편의 가이드 체크리스트)는
/// 15.8형(약 139.5 PPI)에서 약 27 물리 px, 캔버스 기준 약 13.2 — 가장 작은 글자(머리말 17)도 그 위다.
abstract final class _Idle {
  static const double side = 24; // 좌우 여백(시안 B 26)
  static const double topRow = 60; // 위 줄 — 시계·날짜·메뉴(시안 B 62)
  static const double airIcon = 28; // 조용한 시간 공기 줄 아이콘
  static const double columnGap = 24; // 왼쪽(할 일·가전)과 오른쪽 줄 칸 사이(시안 B 26)
  static const double sideWidth = 220; // 오른쪽 줄 칸 폭(시안 B 250 — 캔버스가 그림보다 좁다)
  static const double sideLarge = 250; // 큰 글씨 오른쪽 줄 칸 폭
  static const double featuredGap = 14; // '무엇을 할까요?' 카드와 가전 줄 사이
  static const double tileArt = 56; // 가전 칸 그림(시안 B 54)
  // 조용한 시간 시계 하한 — 다음 루틴·나쁜 공기가 아래에 다 들어가게.
  static const double clockMin = 72;
  static const double clockLargeMin = 44; // 큰 글씨 조용한 시간 시계 하한
  static const double nextGap = KioskSpace.sm; // 시계·공기와 다음 루틴 사이(조용한 시간)
  static const double airGap = 14; // 시계와 공기 줄 사이(조용한 시간)
  static const double stripMax = 164; // 가전 줄 최대 높이 — 남는 높이가 있어도 칸이 너무 커지지 않게
  // 가전 줄 하한 — 이보다 낮아지면 '무엇을 할까요?' 카드를 접는다. 타일 높이 102(실패널 약 209px)라 이름·상태가 다 보인다.
  static const double stripTightMin = 118;
  static const double stripLarge = 156; // 큰 글씨 가전 줄 최대 높이
  static const double stripLargeMin = 128; // 큰 글씨 가전 줄 하한
  static const double stripPad = 16; // 줄 높이 − 타일 높이
  static const double slack = 8; // 조용한 시간 칸 여유(실패널 글꼴이 시험 글꼴보다 넓다)
  static const double stripName = KioskType.body; // 가전 이름
  // 가전 상태 — 본문 단계(휴리스틱 평가 10/18: 실패널 1~2 m에서 작은 글자 띠가 읽히지 않았다).
  static const double stripStatus = KioskType.body;
}

/// 공기 줄은 나쁠 때(나쁨·매우 나쁨)만(사용자 결정 10/18) — 평소(좋음·보통)에는 그 자리에 다음 루틴을 담담하게 적는다.
/// 공기청정기 전원은 가전 타일이 말하므로 공기 줄에서 뺐다.
KioskAirReading? airIfBad(KioskAirReading? air) =>
    air != null && (air.grade == 'BAD' || air.grade == 'VERY_BAD') ? air : null;

/// 다음 루틴 — 시계 아래 담담한 묶음(사용자 결정 10/18, 오른쪽 큰 카드를 대신한다).
///
/// - 머리말(작은 회색): '자동 루틴'(카드 없이 자동으로 하는 회차만) · '물어볼 루틴' · '알림 루틴' · '다음 루틴'([KioskNextRun.kindLabel]).
/// - 본 줄: '오후 10:00 · 저녁 공기청정기 켜기'(오늘이면 날 말 없이, 분까지 — 폰과 같은 꼴). 한 줄에 다 안 들어가면 시각 뒤에서
///   줄을 바꾼다(이름 가운데서 꺾여 '켜기'만 홀로 남지 않게).
/// - 끝 줄: 작은 글자 단추 '오늘은 건너뛰기' — 머리말과 같은 작은 글씨·회색 계열, 테두리 없음(사용자 요청 10/18 — 테두리 단추가 너무
///   튀었다). 누르는 자리는 높이·폭 48 이상(실패널 약 98px). 건너뛰었으면 '오늘은 건너뛰어요 · 되돌리기' 같은 꼴.
///   조용한 시간이라 이미 건너뛰는 회차는 단추 대신 그 이유만. 실패 안내가 있으면 잠시 단추 앞에.
/// 끝 줄은 단추 옆 남는 폭에서 줄을 바꾸고, 그 폭이 너무 좁으면(넓은 글꼴·큰 글씨) 단추를 아래로 내린다 — 높이는
/// [heightFor]가 화면과 같은 규칙으로 잰다(시계·타일 높이를 정한다).
class _NextRunLine extends StatelessWidget {
  const _NextRunLine(
      {super.key, required this.next, this.busy = false, this.notice, this.onToggle, this.stacked = false});

  final KioskNextRun next;

  /// 처음 화면 오른쪽 줄 칸(시안 B 10/24) — 좁은 칸이라 '오후 10:00'(굵게) 뒤 이름을 작은 글자로 이어 쓰고 줄을 바꾼다
  /// (말줄임으로 이름 끝을 자르지 않는다). 조용한 시간 화면은 종전 한 줄 꼴.
  final bool stacked;
  final bool busy;
  final String? notice;
  final ValueChanged<KioskNextRun>? onToggle;

  static const double _headIcon = KioskType.caption + 2;
  static const double _iconGap = 6;
  static const double _headGap = 2;
  static const double _lineGap = 2;
  static const double _wordGap = KioskSpace.xs;
  static const double _minWordWidth = 72;
  static const double _buttonMin = 48;
  static const double _buttonPadH = 6;
  static const _headStyle = TextStyle(fontSize: KioskType.caption, height: 1.2);
  static const _lineStyle = TextStyle(fontSize: KioskType.body, height: 1.25);
  static const _wordStyle = TextStyle(fontSize: KioskType.caption, height: 1.2);
  // 단추 글자는 머리말과 같은 크기·회색 계열 — 굵기만 조금(누르는 말인 줄 알게). 밑줄·테두리는 두지 않는다(사용자 결정
  // 10/18 — 평가 14차가 밑줄을 권했지만 지금 모양이 실패널에서 잘 보인다며 그대로 두기로 했다).
  static const _buttonStyle =
      TextStyle(fontSize: KioskType.caption, height: 1.2, fontWeight: FontWeight.w700);
  static const _noticeStyle = TextStyle(fontSize: KioskType.caption, height: 1.2);
  static const _sep = '·';

  /// '오후 10:00 · 저녁 공기청정기 켜기' — 늘 한 줄(평가 16차 10/18 — 실패널은 한 줄인데 골든에서는 시각 뒤에서 두 줄로
  /// 갈렸다). 넘치면 이름 끝만 말줄임 — 시각이 앞이라 잘리지 않는다.
  static InlineSpan _lineSpan(KioskNextRun n) => TextSpan(children: [
        TextSpan(text: n.whenShort, style: const TextStyle(fontWeight: FontWeight.w700)),
        const TextSpan(text: ' · '),
        TextSpan(text: n.name),
      ]);

  /// 단추 말 — 건너뛰었으면 '되돌리기', 아니면 서버 말('오늘은 건너뛰기'). 둘 수 없으면 null.
  static String? _buttonLabel(KioskNextRun n, bool withButton) =>
      !withButton || !n.canSkip ? null : (n.skipped ? '되돌리기' : n.skipActionLabel);

  static double _buttonWidth(BuildContext context, String label) {
    final w = _textWidth(context, label, _buttonStyle) + 2 * _buttonPadH + 2;
    return w > _buttonMin ? w : _buttonMin;
  }

  static double _buttonHeight(BuildContext context, String label) {
    final h = _textHeight(context, label, _buttonStyle, double.infinity);
    return h > _buttonMin ? h : _buttonMin;
  }

  /// 끝 줄의 말 — 실패 안내가 있으면 잠시 그 안내(줄을 늘리지 않게), 아니면 건너뜀·조용한 시간 말(평소에는 없다).
  static String _wordOf(KioskNextRun n, String? notice) =>
      notice != null && notice.isNotEmpty ? notice : n.statusWord;

  /// 말과 단추 사이 구분점(건너뛴 상태 '오늘은 건너뛰어요 · 되돌리기'). 실패 안내 뒤에는 두지 않는다.
  static bool _withSep(KioskNextRun n, String? notice) =>
      (notice == null || notice.isEmpty) && n.skipped && !n.quietSkip;

  static double _sepWidth(BuildContext context) =>
      _textWidth(context, _sep, _wordStyle) + 2 * _wordGap;

  /// 건너뛴 회차의 '되돌리기'는 머리말 '○○ 루틴 · 오늘은 안 해요' 끝에 붙인다 — 되돌리는 바로 그 말 옆(평가 10/19
  /// 실패널: 시각·이름 줄 아래 혼자 떨어져 무엇을 되돌리는지 몰랐다). 시각·이름 줄 끝에 두면 이름이 말줄임으로 잘려
  /// 그 줄은 비운다. 끝 줄에 다른 말(실패 안내)이 있거나 머리말 옆 폭이 모자라면(넓은 글꼴·큰 글씨) 종전대로 끝 줄.
  /// 머리말 옆에서는 단추 오른쪽 여백을 두지 않는다(줄 끝이라 필요 없다) — 누르는 높이 48은 그대로. 사이는 [_wordGap].
  /// 넓은 글꼴로 조금 모자라면 '오늘은 안 해요'만 10% 안에서 줄인다(머리말의 FittedBox) — 그보다 모자라면 끝 줄.
  static bool _undoOnHead(BuildContext context, KioskNextRun n, String? label, String word, double width) {
    final h = n.skippedHead;
    if (label == null || h == null || word.isNotEmpty) return false;
    final skippedW = _textWidth(context, h, _headStyle.copyWith(fontWeight: FontWeight.w700));
    final head = _headIcon +
        _iconGap +
        _textWidth(context, n.kindLabel, _headStyle) +
        _textWidth(context, ' · ', _headStyle) +
        skippedW;
    return head + _wordGap + _headButtonWidth(context, label) - width <= skippedW * 0.1;
  }

  static double _headButtonWidth(BuildContext context, String label) {
    final w = _textWidth(context, label, _buttonStyle) + 2;
    return w > _buttonMin ? w : _buttonMin;
  }

  static double _headHeight(BuildContext context) {
    final t = _textHeight(context, '자동 루틴', _headStyle, double.infinity);
    return t > _headIcon ? t : _headIcon;
  }

  /// 좁은 칸 꼴([stacked])의 시각·이름 — 첫 줄은 시각(굵게), 둘째 줄부터 이름(작게, 시안 B). 늘 시각 뒤에서만 줄을 바꾼다
  /// (이름 가운데서 꺾여 '켜기'만 홀로 남지 않게 — 평가 16차 10/18의 뜻). 이름이 아주 길면 이름 안에서 낱말 단위로.
  static InlineSpan _stackedSpan(KioskNextRun n) => TextSpan(children: [
        TextSpan(text: n.whenShort, style: const TextStyle(fontWeight: FontWeight.w700)),
        const TextSpan(text: '\n'),
        TextSpan(text: keepWords(n.name), style: const TextStyle(fontSize: KioskType.caption)),
      ]);
  static const int _stackedMaxLines = 3;

  /// 폭 [width]에서 이 묶음이 차지할 높이.
  static double heightFor(BuildContext context, KioskNextRun n, double width,
      {bool withButton = true, String? notice, bool stacked = false}) {
    final headH = _headHeight(context);
    final lineH = stacked
        ? _spanHeight(context, _stackedSpan(n), _lineStyle, width, maxLines: _stackedMaxLines)
        : _textHeight(context, '오후 10:00', _lineStyle, double.infinity);
    final word = keepWords(_wordOf(n, notice));
    final label = _buttonLabel(n, withButton);
    final after = n.afterSkipText;
    final afterH = after == null ? 0.0 : _lineGap + _textHeight(context, keepWords(after), _wordStyle, width);
    if (_undoOnHead(context, n, label, word, width)) {
      final bh = _buttonHeight(context, label!);
      return (headH > bh ? headH : bh) + _headGap + lineH + afterH;
    }
    var h = headH + _headGap + lineH + afterH;
    if (label == null) {
      if (word.isNotEmpty) h += _lineGap + _textHeight(context, word, _wordStyle, width);
    } else {
      final bw = _buttonWidth(context, label);
      final bh = _buttonHeight(context, label);
      final sep = _withSep(n, notice) ? _sepWidth(context) : _wordGap;
      final room = width - bw - sep;
      if (word.isEmpty) {
        h += bh;
      } else if (room >= _minWordWidth) {
        final wh = _textHeight(context, word, _wordStyle, room);
        h += wh > bh ? wh : bh;
      } else {
        h += _lineGap + _textHeight(context, word, _wordStyle, width) + bh;
      }
    }
    return h;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final width = box.maxWidth;
        final skipped = next.skipped && !next.quietSkip;
        final word = next.statusWord;
        final shownNotice = notice != null && notice!.isNotEmpty ? notice : null;
        final label = _buttonLabel(next, onToggle != null);
        final wordText = shownNotice != null
            // 실패 안내(서버 말 그대로 또는 짧은 말)는 잠시 단추 앞에 — 앰버.
            ? KioskText(shownNotice,
                textKey: const ValueKey('idle-next-run-notice'),
                style: _noticeStyle.copyWith(color: KioskColors.warning))
            : word.isEmpty
                ? null
                : KioskText(word,
                    textKey: const ValueKey('idle-next-run-word'),
                    // 건너뛰었으면 그 말이 이 묶음의 요점이다 — 같은 작은 글씨로 흰색 굵게. 조용한 시간은 회색.
                    style: _wordStyle.copyWith(
                        color: skipped ? KioskColors.ink : KioskColors.muted,
                        fontWeight: skipped ? FontWeight.w700 : null));
        final undoOnHead = _undoOnHead(context, next, label, shownNotice ?? word, width);
        final undoButton = undoOnHead
            ? _SkipButton(
                key: const ValueKey('idle-next-run-unskip'),
                label: label!,
                width: _headButtonWidth(context, label),
                padRight: 0,
                minHeight: _buttonMin,
                busy: busy,
                onTap: () => onToggle?.call(next),
              )
            : null;
        Widget? last;
        if (undoOnHead) {
          last = null;
        } else if (label == null) {
          last = wordText == null
              ? null
              : Padding(padding: const EdgeInsets.only(top: _lineGap), child: wordText);
        } else {
          final bw = _buttonWidth(context, label);
          final button = _SkipButton(
            key: ValueKey(next.skipped ? 'idle-next-run-unskip' : 'idle-next-run-skip'),
            label: label,
            width: bw,
            minHeight: _buttonMin,
            busy: busy,
            onTap: () => onToggle?.call(next),
          );
          final withSep = _withSep(next, notice);
          final sepW = withSep ? _sepWidth(context) : _wordGap;
          if (wordText == null) {
            last = button;
          } else if (width - bw - sepW >= _minWordWidth) {
            last = Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Flexible(child: wordText),
              if (withSep)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: _wordGap),
                  child: Text(_sep, style: _wordStyle.copyWith(color: KioskColors.muted)),
                )
              else
                const SizedBox(width: _wordGap),
              button,
            ]);
          } else {
            last = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const SizedBox(height: _lineGap),
              wordText,
              button,
            ]);
          }
        }
        final after = next.afterSkipText;
        final spoken = [
          next.kindLabel,
          if (next.skippedHead case final h?) h,
          next.whenShort,
          next.name,
          if (word.isNotEmpty) word,
          if (after != null) after,
        ].join(', ');
        // 건너뛴 회차 — 언제 다시 하는지(본체 값, 폰과 같은 말 'QA 10/25'). 시각·이름 줄 바로 아래 작은 글씨. 값이 없으면 없다.
        final afterLine = after == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: _lineGap),
                child: KioskText(after,
                    textKey: const ValueKey('idle-next-run-after-skip'),
                    style: _wordStyle.copyWith(color: KioskColors.ink)),
              );
        final head = SizedBox(
          height: _headHeight(context),
          child: Row(key: const ValueKey('idle-next-run-kind'), mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.schedule, size: _headIcon, color: KioskColors.muted),
            const SizedBox(width: _iconGap),
            Text(next.kindLabel,
                maxLines: 1,
                softWrap: false,
                style: _headStyle.copyWith(color: KioskColors.muted)),
            // 건너뛴 회차 — 머리말 옆에 말로(2차 독립 평가 B). 시각·이름 줄은 그대로 남기되 흐리게.
            // 폭이 모자라면(넓은 글꼴·큰 글씨) 이 말만 칸에 맞춰 조금 줄인다 — 잘리지 않게.
            if (next.skippedHead case final h?)
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(' · ', style: _headStyle.copyWith(color: KioskColors.muted)),
                    Text(h,
                        key: const ValueKey('idle-next-run-skipped-head'),
                        maxLines: 1,
                        softWrap: false,
                        style: _headStyle.copyWith(color: KioskColors.ink, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
          ]),
        );
        // 조금 넘치면(15% 안) 글자를 살짝 줄여 이름 끝('켜기')까지 보이고, 그보다 길면 이름 끝만 말줄임.
        final Widget lineWidget = () {
          if (stacked) {
            return Text.rich(_stackedSpan(next),
                key: const ValueKey('idle-next-run-text'),
                maxLines: _stackedMaxLines,
                overflow: TextOverflow.ellipsis,
                style: _lineStyle.copyWith(color: skipped ? KioskColors.muted : KioskColors.ink));
          }
          final line = Text.rich(_lineSpan(next),
              key: const ValueKey('idle-next-run-text'),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              // 건너뛴 회차는 흐리게 — 무엇을 건너뛰는지는 그대로 읽힌다.
              style: _lineStyle.copyWith(color: skipped ? KioskColors.muted : KioskColors.ink));
          final natural = _spanWidth(context, _lineSpan(next), _lineStyle);
          if (natural <= width || natural * 0.85 > width) return line;
          return SizedBox(
              width: width,
              child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: line));
        }();
        final undo = undoButton;
        if (undo != null) {
          // 머리말 끝에 '되돌리기' — 글은 한 덩이로 읽고, 단추는 그 뒤 따로 누르는 자리로 남긴다.
          return Semantics(
            container: true,
            label: spoken,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  key: const ValueKey('idle-next-run-head-row'),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Flexible(child: ExcludeSemantics(child: head)),
                    // 구분점은 두지 않는다(10/19 — '되돌리기'만) — 간격으로만 가른다.
                    const SizedBox(width: _wordGap),
                    // 글 덩이에 합쳐지지 않게 제 낭독 칸으로.
                    Semantics(container: true, child: undo),
                  ],
                ),
                const SizedBox(height: _headGap),
                ExcludeSemantics(child: lineWidget),
                if (afterLine != null) ExcludeSemantics(child: afterLine),
              ],
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              container: true,
              label: spoken,
              excludeSemantics: true,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    head,
                    const SizedBox(height: _headGap),
                    lineWidget,
                    if (afterLine != null) afterLine,
                  ]),
            ),
            if (last != null) last,
          ],
        );
      });
}

/// '오늘은 건너뛰기'·'되돌리기'·공기 줄 할 일 — 작은 글자 단추(테두리·면 없음, 사용자 요청 10/18). 글자는 머리말과 같은 작은
/// 회색 계열 굵은 글자(밑줄·테두리 없음 — 사용자 결정 10/18), 누르는 자리는 높이·폭 [minHeight] 이상. 보내는 중에는 눌리지
/// 않고 더 흐려진다.
class _SkipButton extends StatelessWidget {
  const _SkipButton({
    super.key,
    required this.label,
    required this.width,
    required this.minHeight,
    required this.busy,
    required this.onTap,
    this.padRight = 2 * _NextRunLine._buttonPadH,
  });

  final String label;
  final double width;

  /// 글자 오른쪽 여백 — 머리말 옆 '되돌리기'는 0([_NextRunLine._undoOnHead]).
  final double padRight;
  final double minHeight;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        enabled: !busy,
        label: label,
        excludeSemantics: true,
        child: SizedBox(
          width: width,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: busy ? null : onTap,
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: minHeight),
                child: Padding(
                  // 글자 왼쪽을 위 줄과 맞춘다 — 여백은 오른쪽에만.
                  padding: EdgeInsets.only(right: padRight),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    heightFactor: 1,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(label,
                          maxLines: 1,
                          softWrap: false,
                          style: _NextRunLine._buttonStyle.copyWith(
                              color: busy
                                  ? KioskColors.muted.withValues(alpha: 0.5)
                                  : KioskColors.muted)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

/// 날짜 옆 실내 온습도(사용자 요청 10/20) — 온도계 '24°' · 물방울 '57%'. 날짜와 같은 글자·색, 아이콘은 글자 크기.
/// 화면 읽기는 한 덩어리로 '실내 온도 24도, 습도 57퍼센트'.
class _IndoorEnv extends StatelessWidget {
  const _IndoorEnv({required this.temperature, this.humidity});

  final double temperature;
  final double? humidity;

  /// 날짜와 같은 글자.
  static TextStyle get style => TextStyle(fontSize: KioskType.caption, height: 1.2, color: KioskColors.muted);

  /// 날짜와 온습도 사이, 두 조각 사이.
  static const double gap = KioskSpace.sm;
  static const double _iconGap = 2;

  String get _temp => temperature.toStringAsFixed(0);
  String? get _hum => humidity?.toStringAsFixed(0);

  String get _label => _hum == null ? '실내 온도 $_temp도' : '실내 온도 $_temp도, 습도 $_hum퍼센트';

  static double _icon(BuildContext context) => MediaQuery.textScalerOf(context).scale(KioskType.caption);

  @override
  Widget build(BuildContext context) {
    final icon = _icon(context);
    final hum = _hum;
    Widget piece(IconData data, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(data, size: icon, color: KioskColors.muted),
          const SizedBox(width: _iconGap),
          Text(text, maxLines: 1, softWrap: false, style: style),
        ]);
    return Semantics(
      key: const ValueKey('idle-env'),
      container: true,
      label: _label,
      excludeSemantics: true,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        piece(Icons.thermostat, '$_temp°'),
        if (hum != null) ...[const SizedBox(width: gap), piece(Icons.water_drop, '$hum%')],
      ]),
    );
  }
}

/// 한 줄 글의 폭 — [Text]와 같은 기본 글꼴·배율로 잰다.
double _textWidth(BuildContext context, String text, TextStyle style) {
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

/// 여러 조각 글의 한 줄 폭 — [Text.rich]와 같은 기본 글꼴·배율로 잰다.
double _spanWidth(BuildContext context, InlineSpan span, TextStyle style) {
  final tp = TextPainter(
    text: TextSpan(style: DefaultTextStyle.of(context).style.merge(style), children: [span]),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final w = tp.width;
  tp.dispose();
  return w;
}

/// 여러 조각 글의 높이 — [Text.rich]와 같은 기본 글꼴·배율로 [maxWidth] 안에서 잰다.
double _spanHeight(BuildContext context, InlineSpan span, TextStyle style, double maxWidth, {int? maxLines}) {
  final tp = TextPainter(
    text: TextSpan(style: DefaultTextStyle.of(context).style.merge(style), children: [span]),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: maxLines,
  )..layout(maxWidth: maxWidth < 0 ? 0 : maxWidth);
  final h = tp.height;
  tp.dispose();
  return h;
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
    // 칩은 자리가 좁아 이름과 남은 시간만 — 쉬는 범위는 누르면 열리는 창과 메뉴가 늘 말한다(UX 문구 기준 10/19 §4).
    final title = quiet != null ? '조용한 시간' : kDndName;
    final sub = quiet != null ? '$quiet까지' : '$remaining 남았어요';
    return Semantics(
      button: true,
      label: quiet != null
          ? '조용한 시간, $quiet까지. 새 제안과 일반 안내 소리를 내지 않아요'
          : on
              ? '방해 금지 켜짐, $remaining 남았어요. 끄려면 누르세요'
              : kDndName,
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
                      Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.pause_circle_outline, size: 28, color: KioskColors.muted),
                        KioskTopIconLabel(kDndName),
                      ])
                    else
                      // 아이콘 규칙(평가 7차 10/18, 폰과 같이): 조용한 시간 = 달, 방해 금지 = 일시정지.
                      Icon(quiet != null ? Icons.bedtime : Icons.pause_circle, size: 30, color: KioskColors.ink),
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
                              style: TextStyle(
                                  fontSize: KioskType.body,
                                  height: 1.15,
                                  fontWeight: FontWeight.w700,
                                  color: KioskColors.ink)),
                          Text(sub,
                              maxLines: 1,
                              softWrap: false,
                              style: TextStyle(
                                  fontSize: KioskType.body,
                                  height: 1.15,
                                  color: KioskColors.ink)),
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

/// 실내 공기 — 나쁠 때만 보이는 한 줄(색 + 말, 사용자 결정 10/18)과 아래 작은 줄(연습 값). 1~2 m에서 읽히게 앞 글은 굵게.
/// 숫자와 등급 출처는 LG 상세의 '자세히' 안에 둔다(2차 평가 10/18).
class _AirLine extends StatelessWidget {
  const _AirLine({super.key, required this.air, this.compact = false});
  final KioskAirReading air;

  /// 큰 글씨 모드(지금은 꼴이 같다 — 전원 줄을 뺀 뒤 작은 줄은 연습 값뿐이다).
  final bool compact;

  static const _headStyle =
      TextStyle(fontSize: KioskType.status, height: 1.2, fontWeight: FontWeight.w600);
  static const _subStyle = TextStyle(fontSize: KioskType.body, height: 1.3);

  /// 아래 작은 줄 — 연습 값 안내만(사용자 결정 10/18: 공기청정기 전원은 가전 타일이 말하므로 공기 줄에서 뺐다).
  static List<String> _subOf(KioskAirReading air) =>
      air.sub.where((d) => d == kPracticeNumbers).toList();

  /// 폭 [width]에서 이 줄이 차지할 높이(보통 글씨) — 평소 화면이 가전 타일 높이를 정할 때 쓴다.
  static double heightFor(BuildContext context, KioskAirReading air, double width) {
    final w = width - _Idle.airIcon - KioskSpace.sm;
    final word = kAirGradeSentences[air.grade] ?? air.gradeWord;
    var h = _textHeight(context, '공기 ${keepWords(word)}', _headStyle.copyWith(fontWeight: FontWeight.w800), w);
    final sub = _subOf(air);
    if (sub.isNotEmpty) h += _textHeight(context, keepWords(sub.join('   ')), _subStyle, w);
    return h;
  }


  @override
  Widget build(BuildContext context) {
    // 공기는 한 줄 + 색(2차 평가 10/18) — '공기 보통이에요'. 숫자·'종합은 가전이 매긴 등급'은 LG 상세의 '자세히' 안.
    // 색만으로 말하지 않는다 — 등급 말이 늘 함께 있다.
    final color = airGradeColor(air.grade);
    final word = kAirGradeSentences[air.grade] ?? air.gradeWord;
    final sub = _subOf(air);
    return Semantics(
      container: true,
      label: [air.sentence, ...sub].join('. '),
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
                // 낱말 단위로 줄을 바꾼다(평가 12차 10/18 — 큰 글씨에서 '공기 아주 나빠 / 요'로 한 글자만 꺾였다).
                Text.rich(
                  TextSpan(children: [
                    TextSpan(text: '공기 ', style: TextStyle(color: KioskColors.ink)),
                    TextSpan(text: keepWords(word),
                        semanticsLabel: word,
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

/// 공기 나쁨 줄의 할 일(평가 14차 10/18) — 공기청정기 상태만큼: 켜져 있으면 '바람을 세게 해 보세요', 꺼져 있으면
/// '공기청정기를 켜 보세요', 모르면 '공기청정기 보기'. 누르면 그 가전 화면이 열리고, 바꾸는 것은 그 화면에서 사람이 고른다.
String airActionLabel(KioskAirReading air, String applianceName) => switch (air.power) {
      'on' => '바람을 세게 해 보세요',
      'off' => '${withObject(applianceName)} 켜 보세요',
      _ => '$applianceName 보기',
    };

class _StripNotice extends StatelessWidget {
  const _StripNotice(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 누를 수 없는 안내다 — '+'는 단추로 읽혔다(2026-10-15 B5).
          Icon(Icons.info_outline,
              size: 26, color: KioskColors.muted),
          const SizedBox(width: 10),
          // 큰 글씨에서는 줄을 바꾼다(넘치지 않게).
          Flexible(
            child: KioskText(text,
                style: TextStyle(fontSize: _Idle.stripName, color: KioskColors.muted)),
          ),
        ],
      );
}

IconData _tipIcon(String icon) => switch (icon) {
      'rain' => Icons.umbrella,
      'snow' => Icons.ac_unit,
      'hot' => Icons.wb_sunny,
      'cold' => Icons.thermostat,
      // 루틴 안내(세탁 끝·복약, 2026-10-06) — 경고가 아니라 알림이다.
      'notice' => Icons.notifications_none_outlined,
      _ => Icons.error_outline,
    };

/// 날씨 안내인가(비·눈·더위·추위) — 예보 줄을 카드 안에 품는다. 알림(루틴 안내·확인 필요 가전·위험 소리)은 아니다(평가 15차 10/18).
/// 종류(kind)를 모르는 옛 서버면 아이콘으로 본다.
bool isWeatherTip(AmbientTip tip) {
  const kinds = {'rain', 'snow', 'heat', 'cold'};
  if (tip.kind.isNotEmpty) return kinds.contains(tip.kind);
  return const {'rain', 'snow', 'hot', 'cold'}.contains(tip.icon);
}

/// 예보 줄의 한 칸(사용자 요청 10/18) — 맨 앞 '지금' 칸 또는 서버 3시간 칸.
class ForecastSlot {
  const ForecastSlot({required this.label, required this.hour, required this.night, this.isNow = false});

  /// 칸 머리 — '지금' · '오후 3시' · '밤 12시'.
  final String label;
  final AmbientHour hour;

  /// 밤 칸인가(맑음·구름 조금을 달로) — 칸 시각(지금 칸은 지금 시각)으로 가른다.
  final bool night;
  final bool isNow;
}

/// 밤 시간(19~5시)인가. 모르면 낮으로 본다.
bool _nightHour(int? h) => h != null && (h >= 19 || h < 6);

/// 평소 화면 예보 줄의 칸들(사용자 요청 10/18) — 맨 앞 '지금'([outsideNowSlot]), 그 뒤 서버 3시간 칸. 모두 [max]칸까지
/// (1~2 m에서 읽히게 칸을 늘리지 않는다 — 지금 칸이 있으면 예보는 3칸). 지금 칸으로 쓴 서버 칸은 다시 두지 않는다.
List<ForecastSlot> forecastSlots(AmbientInfo? ambient, DateTime now, {int max = 4}) {
  if (ambient == null) return const [];
  final current = outsideNowSlot(ambient, now);
  return [
    if (current != null)
      ForecastSlot(label: '지금', hour: current, night: _nightHour(now.hour), isNow: true),
    for (final h in ambient.hourly.where((h) => !identical(h, current)))
      ForecastSlot(label: hourLabel12(h.label), hour: h, night: _nightHour(h.slotHour)),
  ].take(max).toList(growable: false);
}

/// 예보 줄 첫 칸 '지금'에 쓸 칸(사용자 요청 10/18). 서버 예보(`hourly`)는 3시간 간격 칸이고 다음 경계부터 온다
/// (8:20이면 9·12·15·18시). 칸 시각이 지금 ±90분 안(3시간 칸이 대표하는 범위)이고 기온이 있을 때만 그 칸을 쓴다 —
/// 먼 칸의 값을 지금 날씨처럼 보이지 않는다. 없으면 null(지금 칸을 두지 않는다).
AmbientHour? outsideNowSlot(AmbientInfo? ambient, DateTime now) {
  if (ambient == null) return null;
  // 서버가 `now` 키를 보내면 그 값만 쓴다(평가 15차 10/18) — 서버 '지금'은 날씨 안내 문장과 같은 정의(지난 정시 칸, 없으면
  // 앞뒤 30분 안)다. null이면 '지금' 칸을 두지 않는다: 여기서 3시간 칸을 대신 고르면 오후 2:21에 3시 칸(비)이 '지금'으로
  // 그려져 '오후 3시부터 비' 안내와 엇갈렸다. 키가 없는 옛 서버일 때만 아래 대체(앞뒤 90분 안 3시간 칸).
  if (ambient.nowKnown) {
    final n = ambient.now;
    return n != null && n.temp != null ? n : null;
  }
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

/// 예보 아이콘 — 가전 아이콘과 같은 채움 양식(평가 17차 10/18 — 날씨만 가는 선이었다). 밤의 맑음·구름 조금은 해가 아니라 달(외부 평가 10/16 4차, 실패널 0시·3시에 해가 찍혔다).
IconData _hourIcon(String icon, {bool night = false}) => switch (icon) {
      'clear' when night => Icons.nightlight,
      'partly' when night => Icons.nights_stay,
      'clear' => Icons.wb_sunny,
      'partly' => Icons.wb_cloudy,
      'cloudy' => Icons.cloud,
      // 비는 [_WeatherIcon]이 비 오는 구름으로 그린다 — 물방울은 습도로 읽혔다(평가 10차 10/18). 여기 값은 '아는 날씨' 표시.
      'rain' => Icons.cloud,
      'snow' => Icons.ac_unit,
      _ => Icons.remove,
    };

/// 날씨 아이콘 하나 — 예보 칸이 모두 같은 규칙(평가 10차 10/18). 비는 글꼴에 '비 오는 구름'이 없어 구름 + 빗줄기
/// 세 줄로 그린다(물방울은 습도, 우산은 '챙기세요' 안내로 읽혔다). 나머지는 [_hourIcon].
class _WeatherIcon extends StatelessWidget {
  const _WeatherIcon(this.icon, {this.night = false, required this.size, required this.color});
  final String icon;
  final bool night;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (icon != 'rain') return Icon(_hourIcon(icon, night: night), size: size, color: color);
    return SizedBox(
      key: const ValueKey('weather-rain-cloud'),
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned(
          left: size * 0.05,
          top: -size * 0.1,
          child: Icon(Icons.cloud, size: size * 0.9, color: color),
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

/// 위쪽 칩·메뉴가 여는 큰 창(메뉴·연결 목록)을 들고 있는 껍데기(화면 구조 개편 10/18).
/// 창은 캔버스 안에 그린다(확대·가장자리 여백을 그대로 따른다).
enum _Sheet { none, menu, connections, help }

class _IdleSheets {
  const _IdleSheets(this.openMenu, this.openConnections);
  final VoidCallback openMenu;
  final VoidCallback openConnections;
}

/// 탭 화면(가전 고르기·자동 실행·기록)의 '메뉴'(QA 10/25) — 처음 화면과 **같은** 메뉴 창(방해 금지·설정·연결·사용 방법)을
/// 같은 코드([_IdleSheetHost])로 연다. 메뉴 항목이 쓰는 값·콜백은 처음 화면과 같은 [KioskIdleView] 설정에서 읽는다(그 화면을
/// 그리지는 않는다). [builder]는 메뉴를 여는 콜백을 받아 탭 화면을 만든다.
class KioskMenuHost extends StatelessWidget {
  const KioskMenuHost({super.key, required this.view, required this.builder});

  final KioskIdleView view;
  final Widget Function(VoidCallback openMenu) builder;

  @override
  Widget build(BuildContext context) => _IdleSheetHost(view: view, builder: (sheets) => builder(sheets.openMenu));
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
    // 방해 금지 창과 같은 범위 문장을 늘 둔다(UX 문구 기준 10/19 §4 — 이름을 되돌린 조건). 조용한 시간은 다른 기능이라
    // 이 줄에 섞지 않는다(조용한 시간은 위 줄 칩과 설정이 말한다).
    final scope = dnd != null && v.dndScope == 'suggestions_only' ? kDndCarriedScopeText : kDndScopeText;
    final restSub = dnd != null ? '켜져 있어요. ${v._dndRemaining(dnd)} 남았어요. $scope' : scope;
    return Stack(children: [
      // 창이 떠 있으면 뒤 처음 화면은 화면 읽기에서 뺀다(10/24 QA) — 창만 읽히고 눌린다.
      ExcludeSemantics(child: body),
      // 메뉴·연결·사용 방법 창이 떠 있으면 아래 탭을 숨긴다(실패널 10/24 — 탭이 창 위에 밝게 남고 창의 마지막 줄이 잘렸다).
      const KioskTabBarSuppress(),
      Positioned.fill(
        child: KioskModalSemantics(
        label: switch (_sheet) { _Sheet.help => '사용 방법', _Sheet.menu => '메뉴', _ => '연결' },
        child: _sheet == _Sheet.help
            // 사용 방법 세 장(휴리스틱 평가 10/18).
            ? KioskHelpGuide(onClose: _close)
            : _sheet == _Sheet.menu
            ? KioskIdleSheet(
                title: '메뉴',
                onClose: _close,
                fit: true,
                children: [
                  KioskSheetRow(
                    key: const ValueKey('dnd-entry'),
                    // 방해 금지 = 일시정지(평가 7차 10/18 — 달은 폰에서 조용한 시간이다).
                    icon: dnd != null ? Icons.pause_circle : Icons.pause_circle_outline,
                    label: kDndName,
                    sub: restSub,
                    subMaxLines: null,
                    onTap: () {
                      _close();
                      v.onDndGesture();
                    },
                  ),
                  KioskSheetRow(
                    key: const ValueKey('settings-entry'),
                    hideSubWhenLarge: true,
                    icon: Icons.settings_outlined,
                    label: '설정',
                    sub: '큰 글씨, 또렷하게 보기, 음성 안내, 휴대폰 연결',
                    semanticsLabel: '설정',
                    onTap: () {
                      _close();
                      v.onSettingsGesture?.call();
                    },
                  ),
                  // 모두 괜찮으면 위 상태 칩이 없다(사용자 결정 10/18) — 그때도 연결 상태를 볼 수 있게 메뉴에 둔다.
                  KioskSheetRow(
                    key: const ValueKey('connections-entry'),
                    hideSubWhenLarge: true,
                    icon: Icons.wifi,
                    label: '연결',
                    sub: '와이파이와 누름 장치 연결 보기',
                    onTap: () => setState(() => _sheet = _Sheet.connections),
                  ),
                  // 도움말 들어가는 곳(휴리스틱 평가 10/18 — 메뉴에 잠시 쉬기·설정·연결뿐이었다).
                  KioskSheetRow(
                    key: const ValueKey('help-entry'),
                    hideSubWhenLarge: true,
                    icon: Icons.help_outline,
                    label: '사용 방법',
                    sub: '화면 쓰는 법, 멈추는 법, 물어볼 곳',
                    onTap: () => setState(() => _sheet = _Sheet.help),
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
      ),
    ]);
  }
}

/// 조용한 시간 바탕 짙기(사용자 결정 10/18) — 평소 바탕에 섞는 검정의 양([KioskCanvas.quietBg]). 접근성 감사(10/18)부터 막을 글자
/// 위에 얹지 않고 바탕만 어둡게 한다. 앱 안에서만 어둡게 한다(패널 밝기 장치는 건드리지 않는다). 값은 추측이다(실패널에서 측정 필요).
const double kQuietDimAlpha = KioskCanvas.dimAlpha;

/// 조용한 시간 글자 밝기(접근성 감사 10/18) — 밤에 덜 눈부시게 글자를 이만큼만 낮춘다. 가장 흐린 글자(회색 보조 글자)도 어두운
/// 바탕 위 대비 4.5:1 이상이 남는 값(약 5.5:1, `test/kiosk_a11y_1018_test.dart`가 고정). 값은 추측이다(실패널에서 측정 필요).
const double kQuietTextOpacity = 0.75;

/// 조용한 시간의 처음 화면 — 위 줄(날짜·조용한 시간·문제 칩·메뉴) · 큰 시계 · (나쁘면) 공기 · 다음 루틴만. 예보·인사말·온습도·
/// 가전 줄은 접는다. 바탕만 어둡고(글자 위 막 없음) 글자는 [kQuietTextOpacity]만큼 낮춘다. 화면을 누르면 그 아래 단추는 눌리지
/// 않는다(깨우는 손길 — 다시 밝아지면 고른다).
class _QuietIdle extends StatelessWidget {
  const _QuietIdle({
    required this.view,
    required this.topRow,
    required this.clock,
    required this.large,
    this.air,
  });

  final KioskIdleView view;
  final Widget topRow;
  final String clock;
  final bool large;
  final KioskAirReading? air;

  /// 시계 상한(캔버스) — 1920x1080에서 약 307px. 1~2 m에서 시계가 먼저 읽히게 평소보다 크게.
  static const double _clockMax = 150;

  @override
  Widget build(BuildContext context) {
    final next = view.nextRun;
    return ColoredBox(
      key: const ValueKey('idle-quiet'),
      color: KioskCanvas.quietBg,
      child: Stack(children: [
        Opacity(
          opacity: kQuietTextOpacity,
          child: Padding(
          padding: const EdgeInsets.fromLTRB(_Idle.side, 14, _Idle.side, 10),
          // 시계는 평소 화면과 같은 왼쪽 선에서(가운데로 옮기지 않는다).
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            topRow,
            const SizedBox(height: 8),
            Expanded(
              child: LayoutBuilder(builder: (context, box) {
                final rest = KioskIdleView._leftRest(context, box.maxWidth,
                    air: air, next: next, onToggle: view.onToggleNextRunSkip, notice: view.nextRunNotice);
                final size = (box.maxHeight - rest - _Idle.slack)
                    .clamp(large ? _Idle.clockLargeMin : _Idle.clockMin, _clockMax)
                    .toDouble();
                return SingleChildScrollView(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _Clock(ampm: ampmOf(view.now.hour), digits: clock, size: size),
                    if (air != null) ...[
                      const SizedBox(height: _Idle.airGap),
                      _AirLine(key: const ValueKey('idle-air'), air: air!, compact: large),
                    ],
                    if (next != null) ...[
                      const SizedBox(height: _Idle.nextGap),
                      _NextRunLine(
                          key: const ValueKey('idle-next-run'),
                          next: next,
                          busy: view.nextRunBusy,
                          notice: view.nextRunNotice,
                          onToggle: view.onToggleNextRunSkip),
                    ],
                  ]),
                );
              }),
            ),
          ]),
          ),
        ),
        // 누름을 받는 자리(색 없음) — 그 아래 단추는 눌리지 않는다(깨우는 손길). 어둡게는 바탕이 한다(글자 위 막 없음).
        Positioned.fill(
          child: GestureDetector(
            key: const ValueKey('idle-quiet-dim'),
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: const ColoredBox(color: Colors.transparent),
          ),
        ),
      ]),
    );
  }
}
