import 'package:flutter/material.dart';

import '../../models/ambient.dart';
import '../../models/appliance.dart';
import '../../theme/kiosk_colors.dart';
import 'appliance_strip.dart';
import 'connection_status.dart';

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
  final double? temperature;
  final double? humidity;
  final ValueChanged<ApplianceMap> onSelectAppliance;
  final ValueChanged<ConnectionItem> onOpenConnection;

  /// 위 줄의 방해 금지 단추(꺼짐)·칩(켜짐)을 누르면 방해 금지 선택을 연다.
  final VoidCallback onDndGesture;

  /// 가운데 위 설정 단추를 2초간 길게 누르면 설정 오버레이를 연다.
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
        padding: const EdgeInsets.fromLTRB(28, 10, 28, 4),
        child: Column(children: [
          SizedBox(height: 80, child: Row(children: [
            // 방해 금지 칩이 켜지면 위 줄이 좁아진다 — 날짜는 말줄임 대신 살짝
            // 줄여 다 보인다(큰 글씨+칩에서 약 0.83배 → 보통 글씨 33px 이상 유지).
            Expanded(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
              child: Text(_dateStr, maxLines: 1, softWrap: false,
                style: const TextStyle(fontSize: 33, color: KioskColors.muted)))),
            OutlinedButton.icon(key: const ValueKey('settings-entry'),
              onPressed: onSettingsGesture, icon: const Icon(Icons.settings_outlined),
              label: const Text('설정', style: TextStyle(fontSize: 33))),
            const SizedBox(width: 8),
            _DndEntry(remaining: dnd == null ? null : _dndRemaining(dnd), onTap: onDndGesture),
            KioskConnectionIcons(items: connections, onOpen: onOpenConnection),
          ])),
          Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 5, child: SingleChildScrollView(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_clock,
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(fontSize: large ? 84 : 104, height: 1, color: Colors.white,
                    fontFeatures: const [FontFeature.tabularFigures()])),
                if (envText != null) Text(envText,
                  style: const TextStyle(fontSize: 33, height: 1.25, color: KioskColors.muted)),
              ],
            ))),
            const SizedBox(width: 20),
            Expanded(flex: 6, child: SingleChildScrollView(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showGreeting)
                  Text(greeting, style: const TextStyle(fontSize: 33, height: 1.25, color: Colors.white)),
                if (tip != null)
                  _TipCard(key: const ValueKey('ambient-tip'), tip: tip,
                      compact: large || showHours),
                if (showHours) ...[
                  SizedBox(height: tip != null ? 6 : 10),
                  _Hours(key: const ValueKey('ambient-hours'),
                      hours: amb.hourly.take(4).toList(), compact: tip != null),
                ],
              ],
            ))),
          ])),
          SizedBox(height: large ? 176 : 158, child: Center(child: SingleChildScrollView(child: list == null
            ? const _StripNotice('허브와 연결되면 가전이 보여요')
            : list.isEmpty ? const _StripNotice('앱에서 가전을 추가해 주세요')
            : KioskApplianceStrip(appliances: list, running: running, attention: attention,
                onSelect: onSelectAppliance,
                perPage: large ? 2 : 3,
                itemWidth: large ? 280 : 200)))),
        ]),
      ),
    );
  }
}

/// 위 줄의 방해 금지 자리. 꺼져 있으면 달 아이콘 단추(글자 없음 — 늘 보이는 글자는
/// 켜진 것으로 읽혔다), 켜져 있으면 채운 칩에 아이콘·"방해 금지"·남은 시간을 적는다
/// (색만으로 말하지 않는다). 둘 다 누르면 같은 방해 금지 선택이 열린다.
class _DndEntry extends StatelessWidget {
  const _DndEntry({required this.remaining, required this.onTap});

  /// 남은 시간 문구. null이면 꺼져 있다.
  final String? remaining;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final on = remaining != null;
    return Semantics(
      button: true,
      label: on ? '방해 금지 중, 해제하려면 누르세요' : '방해 금지 켜기',
      child: ExcludeSemantics(
        child: Material(
          color: on ? KioskColors.primary : Colors.transparent,
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
                        color: on ? KioskColors.onAccent : KioskColors.muted),
                    if (on) ...[
                      const SizedBox(width: 6),
                      // 좁은 위 줄에 들어가도록 두 줄로 — "방해 금지" / 남은 시간.
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('방해 금지',
                              maxLines: 1,
                              softWrap: false,
                              textScaler: TextScaler.noScaling,
                              style: TextStyle(
                                  fontSize: 22,
                                  height: 1.15,
                                  fontWeight: FontWeight.w700,
                                  color: KioskColors.onAccent)),
                          Text(remaining!,
                              maxLines: 1,
                              softWrap: false,
                              textScaler: TextScaler.noScaling,
                              style: const TextStyle(
                                  fontSize: 22,
                                  height: 1.15,
                                  color: KioskColors.onAccent)),
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
          const Icon(Icons.add_circle_outline,
              size: 28, color: KioskColors.muted),
          const SizedBox(width: 10),
          Text(text,
              style: const TextStyle(fontSize: 33, color: KioskColors.muted)),
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

  @override
  Widget build(BuildContext context) {
    // 확인이 필요한 가전·위험 소리는 노란색 — 날씨는 강조색.
    final attention = tip.icon == 'attention';
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 16, vertical: compact ? 5 : 8),
      decoration: BoxDecoration(
        color: KioskColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: attention ? KioskColors.warning : KioskColors.border),
      ),
      child: Row(
        children: [
          Icon(_tipIcon(tip.icon),
              size: compact ? 26 : 30,
              color: attention ? KioskColors.warning : KioskColors.primary),
          SizedBox(width: compact ? 8 : 12),
          Expanded(
            // 서버 문장이 아주 길 때만 마지막 수단으로 말줄임한다.
            child: Text(
              tip.text,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 33, height: compact ? 1.15 : 1.2, color: Colors.white),
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

  String _value(AmbientHour h) => h.precip && h.pop != null
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
                        style: TextStyle(
                            fontSize: 33,
                            height: compact ? 1.15 : null,
                            color: KioskColors.muted)),
                  ),
                  if (compact)
                    // 아이콘과 숫자를 한 줄에 — 안내 카드 아래 남은 높이에 맞춘다.
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(_hourIcon(h.icon),
                            size: 22,
                            color: h.precip ? KioskColors.primary : KioskColors.muted),
                        const SizedBox(width: 2),
                        _ValueText(h: h, text: _value(h), height: 1.15),
                      ]),
                    )
                  else ...[
                    const SizedBox(height: 4),
                    Icon(_hourIcon(h.icon),
                        size: 26,
                        color: h.precip ? KioskColors.primary : KioskColors.muted),
                    const SizedBox(height: 4),
                    _ValueText(h: h, text: _value(h)),
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
          fontSize: 33,
          height: height,
          fontWeight: h.precip ? FontWeight.w700 : FontWeight.w500,
          color: h.precip ? Colors.white : KioskColors.muted,
        ),
      );
}
