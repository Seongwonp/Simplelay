import 'package:flutter/material.dart';

import '../../models/ambient.dart';
import '../../models/appliance.dart';
import '../../theme/kiosk_colors.dart';
import 'appliance_strip.dart';
import 'connection_status.dart';
import 'kiosk_text.dart';

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
    this.dndUntil,
    this.quietUntil,
    this.temperature,
    this.humidity,
    required this.onSelectAppliance,
    required this.onOpenConnection,
    required this.onDndGesture,
    this.onSettingsGesture,
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
  final DateTime? dndUntil;

  /// 매일 조용한 시간대 안이면 끝 시각("07:00", 2026-10-14). 잠시 쉬기(방해 금지)가 켜져 있으면 그쪽이 먼저 보인다.
  final String? quietUntil;
  final double? temperature;
  final double? humidity;
  final ValueChanged<ApplianceMap> onSelectAppliance;
  final ValueChanged<ConnectionItem> onOpenConnection;

  /// 위 줄의 방해 금지 단추(꺼짐)·칩(켜짐)을 누르면 방해 금지 선택을 연다.
  final VoidCallback onDndGesture;

  /// 위 줄의 설정 단추(톱니바퀴)를 한 번 누르면 설정 오버레이를 연다.
  final VoidCallback? onSettingsGesture;

  String get _dateStr {
    const wd = ['월', '화', '수', '목', '금', '토', '일'];
    return '${now.month}월 ${now.day}일 ${wd[now.weekday - 1]}요일';
  }

  String get _clock => '${now.hour}:${now.minute.toString().padLeft(2, '0')}';

  /// 허브에 못 닿을 때의 인사말 — 서버(`services/weather/ambient.py`)와 같은 규칙.
  static String localGreeting(DateTime now) {
    final h = now.hour;
    if (h >= 5 && h < 11) return '좋은 아침이에요.';
    if (h >= 11 && h < 17) return '좋은 오후예요.';
    if (h >= 17 && h < 21) return '편안한 저녁 보내세요.';
    return '편안한 밤 보내세요.';
  }

  String? get _envStr {
    final t = temperature;
    if (t == null) return null;
    final hum = humidity == null ? '' : ' · 습도 ${humidity!.toStringAsFixed(0)}%';
    return '실내 ${t.toStringAsFixed(0)}°$hum';
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
        ? amb.greeting
        : localGreeting(now);
    final list = appliances;
    // 큰 글씨 모드(kiosk_screen이 1.22배 textScaler를 얹는다)에서는 같은 800x480
    // 캔버스에 글자만 커지므로, 자르지 않고 **덜 보인다**(2026-10-05 잘림 수리):
    // - 시계는 이미 충분히 커서 배율을 얹지 않고 조금 줄인다.
    // - 온도 줄은 '실내'를 뺀 짧은 꼴로 한 줄에 둔다.
    // - 안내가 있으면 예보 칸은 숨긴다(보통 글씨에서는 안내와 예보를 함께 보인다).
    // - 가전은 한 장에 2개(보통 3개) — 이름·상태를 줄이지 않는다.
    final large = MediaQuery.textScalerOf(context).scale(10) > 10.5;
    final env = _envStr;
    final envText = env == null ? null : (large ? env.replaceFirst('실내 ', '') : env);
    final tip = (amb?.tip != null && amb!.tip!.text.isNotEmpty) ? amb.tip : null;
    // 안내는 한 번에 하나다(UI 확정 §3-1: 확인 필요 가전 → 날씨 → 인사말) —
    // 안내 카드가 있으면 인사말은 접는다. 그 자리에 예보 4칸이 들어간다.
    // 큰 글씨에서는 안내(지금 할 일)가 예보보다 먼저다 — 둘 다 넣으면 아래가 잘린다.
    final showHours = amb != null &&
        amb.hourly.isNotEmpty &&
        !(large && tip != null);
    final showGreeting = tip == null;
    final dnd = dndUntil != null && dndUntil!.isAfter(now) ? dndUntil : null;

    return ColoredBox(
      color: KioskColors.bg,
      child: Padding(
        // 여백을 넉넉히(10/7 "빽빽하다" 수리) — 화면을 끝까지 채우지 않는다.
        padding: const EdgeInsets.fromLTRB(_Idle.side, 14, _Idle.side, 10),
        child: Column(children: [
          SizedBox(height: _Idle.topRow, child: Row(children: [
            // 방해 금지 칩이 켜지면 위 줄이 좁아진다 — 날짜는 말줄임 대신 살짝
            // 줄여 다 보인다.
            Expanded(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
              child: Text(_dateStr, maxLines: 1, softWrap: false,
                style: const TextStyle(fontSize: _Idle.topText, color: KioskColors.muted)))),
            // 설정은 자주 쓰지 않는다 — 금색 글자 알약이 화면에서 가장 밝아 시선을 빼앗았다(2026-10-14).
            // 회색 톱니 아이콘 단추로 두되, 누르는 자리는 48px 이상·읽는 이름은 '설정'.
            Semantics(button: true, label: '설정', excludeSemantics: true, onTap: onSettingsGesture,
              child: IconButton(key: const ValueKey('settings-entry'),
                onPressed: onSettingsGesture,
                tooltip: '설정',
                constraints: const BoxConstraints(minWidth: 56, minHeight: 56),
                color: KioskColors.muted,
                iconSize: 30,
                icon: const Icon(Icons.settings_outlined))),
            const SizedBox(width: 8),
            _DndEntry(
                remaining: dnd == null ? null : _dndRemaining(dnd),
                quietUntil: dnd == null ? quietUntil : null,
                onTap: onDndGesture),
            KioskConnectionIcons(items: connections, onOpen: onOpenConnection),
          ])),
          const SizedBox(height: 8),
          Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 5, child: SingleChildScrollView(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_clock,
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(fontSize: large ? 84 : 104, height: 1, color: Colors.white,
                    fontFeatures: const [FontFeature.tabularFigures()])),
                if (envText != null) ...[
                  const SizedBox(height: 6),
                  Text(envText,
                    style: const TextStyle(fontSize: _Idle.envText, height: 1.25, color: KioskColors.muted)),
                ],
              ],
            ))),
            const SizedBox(width: _Idle.columnGap),
            Expanded(flex: 6, child: LayoutBuilder(builder: (context, box) {
              // 예보는 이 화면에서 가장 덜 중요하다 — 남은 높이에 다 들어가지 않으면
              // (비상정지 띠가 위 한 줄을 차지할 때 등) 반쯤 걸치게 두지 않고 접는다
              // (2026-10-06 실패널: 띠가 생기자 예보 위쪽이 가전 줄에 걸려 잘렸다).
              final hourly = showHours ? amb.hourly.take(4).toList() : const <AmbientHour>[];
              final hoursFit = showHours &&
                  _rightColumnHeight(context, box.maxWidth,
                          greeting: showGreeting ? greeting : null,
                          tip: tip,
                          hours: hourly,
                          large: large) <=
                      box.maxHeight;
              return SingleChildScrollView(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showGreeting)
                    Text(greeting, style: const TextStyle(
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
              ));
            })),
          ])),
          const SizedBox(height: 8),
          SizedBox(height: large ? 156 : _Idle.strip, child: Center(child: SingleChildScrollView(child: list == null
            ? const _StripNotice('SimpleLay 본체와 연결되면 가전이 보여요')
            : list.isEmpty ? const _StripNotice('휴대폰 SimpleLay 앱에서 가전을 추가해 주세요')
            : KioskApplianceStrip(appliances: list, running: running, attention: attention,
                onSelect: onSelectAppliance,
                perPage: large ? 2 : 3,
                itemWidth: large ? 230 : 170,
                labelSize: _Idle.stripName,
                statusSize: _Idle.stripStatus,
                iconBox: 52)))),
        ]),
      ),
    );
  }

  /// 오른쪽 칸(인사말 또는 안내 + 예보)이 [width] 폭에서 차지할 높이. 화면과 같은
  /// 글꼴·배율로 잰다 — 예보를 넣을지 정하는 데만 쓴다.
  static double _rightColumnHeight(BuildContext context, double width,
      {String? greeting, AmbientTip? tip, required List<AmbientHour> hours, required bool large}) {
    var h = 0.0;
    if (greeting != null) {
      h += _textHeight(context, greeting,
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

/// 평소 화면 치수(캔버스 800x480 기준 논리 px, 1920x1080 실패널에서는 2.05배).
///
/// 글자 하한: 고령층 키오스크 지침의 14pt(사용자편의 가이드 체크리스트)는
/// 15.8형(약 139.5 PPI)에서 약 27 물리 px, 캔버스 기준 약 13.2 — 가장 작은
/// 글자(예보 시각 18)도 그 위다. 위계는 시계 > 인사말·안내 > 가전·예보 순.
abstract final class _Idle {
  static const double side = 44; // 좌우 여백(전 28)
  static const double topRow = 64; // 위 줄(전 80)
  static const double topText = 24; // 날짜·설정(전 33)
  static const double envText = 22; // 실내 온습도(전 33)
  static const double columnGap = 40; // 시계 칸과 안내 칸 사이(전 20)
  static const double greeting = 28; // 인사말(전 33)
  static const double tipText = 24; // 안내 카드 글자(전 33)
  static const double tipIcon = 24; // 안내 카드 아이콘(전 30)
  static const double hourLabel = 18; // 예보 시각(전 33)
  static const double hourValue = 20; // 예보 값(전 33)
  static const double hourIcon = 18; // 예보 아이콘(전 26·22)
  static const double hoursGap = 14;
  static const double hoursGapTip = 10;
  static const double strip = 128; // 가전 줄 높이(전 158)
  static const double stripName = 22; // 가전 이름(전 33)
  static const double stripStatus = 18; // 가전 상태(전 33)
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
  const _DndEntry({required this.remaining, required this.onTap, this.quietUntil});

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
    final title = quiet != null ? '조용한 시간' : '제안 쉬는 중';
    final sub = quiet != null ? '$quiet까지' : '$remaining 남음';
    return Semantics(
      button: true,
      label: quiet != null
          ? '조용한 시간, $quiet까지. 새 제안과 일반 안내 소리를 쉬어요'
          : on
              ? '제안 쉬는 중, $remaining 남음. 다시 받으려면 누르세요'
              : '제안 잠시 쉬기',
      child: ExcludeSemantics(
        child: Material(
          // 쉬는 중은 일상 상태 — 중립 회색 면(2026-10-16 디자인 규격 §1-4). 앰버 채움은 주요 행동 몫이다.
          color: on ? KioskColors.surface2 : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            key: const ValueKey('dnd-entry'),
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
                    Icon(on ? Icons.bedtime : Icons.bedtime_outlined,
                        size: 30,
                        color: on ? Colors.white : KioskColors.muted),
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
                                  fontSize: 20,
                                  height: 1.15,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white)),
                          Text(sub,
                              maxLines: 1,
                              softWrap: false,
                              style: const TextStyle(
                                  fontSize: 20,
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
            child: Text(text,
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
    final text = _textHeight(context, tip.text, _style(compact), textWidth,
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
              tip.text,
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

IconData _hourIcon(String icon) => switch (icon) {
      'clear' => Icons.wb_sunny_outlined,
      'partly' => Icons.wb_cloudy_outlined,
      'cloudy' => Icons.cloud_outlined,
      'rain' => Icons.water_drop_outlined,
      'snow' => Icons.ac_unit,
      _ => Icons.remove,
    };

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
          _textHeight(context, h.label, _labelStyle(compact), double.infinity);
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

  static String _valueOf(AmbientHour h) => h.precip && h.pop != null
      ? '${h.pop}%'
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
                    child: Text(h.label,
                        maxLines: 1,
                        softWrap: false,
                        style: _labelStyle(compact)
                            .copyWith(color: KioskColors.muted)),
                  ),
                  if (compact)
                    // 아이콘과 숫자를 한 줄에 — 안내 카드 아래 남은 높이에 맞춘다.
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(_hourIcon(h.icon),
                            size: _Idle.hourIcon,
                            // 비 오는 칸은 아이콘 모양과 밝기로 — 앰버는 쓰지 않는다(§1-4).
                            color: h.precip ? Colors.white : KioskColors.muted),
                        const SizedBox(width: 2),
                        _ValueText(h: h, text: _valueOf(h), height: 1.2),
                      ]),
                    )
                  else ...[
                    const SizedBox(height: 4),
                    Icon(_hourIcon(h.icon),
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
