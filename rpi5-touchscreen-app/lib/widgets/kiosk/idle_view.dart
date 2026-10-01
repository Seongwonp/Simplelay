import 'package:flutter/material.dart';

import '../../models/ambient.dart';
import '../../models/appliance.dart';
import '../../theme/kiosk_colors.dart';
import 'appliance_strip.dart';
import 'connection_status.dart';

/// 평소 화면(UI 확정 2026-09-30 §3-1) — 집에 붙은 시계처럼.
///
/// - 위 줄: 왼쪽 날짜, 가운데 설정 진입, 오른쪽 연결 아이콘 세 개(문제면 "!").
/// - 가운데 왼쪽: 큰 시계와 실내 온도·습도. 길게 누르면 방해 금지.
/// - 가운데 오른쪽: 인사말, 안내 한 줄(서버가 고른 하나), 시간대 예보 4칸.
/// - 아래: 등록된 가전 아이콘 줄(4개씩, 확인 필요 → 동작 중 → 나머지).
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

  /// 시계를 길게 누르면 방해 금지 선택을 연다.
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
    final env = _envStr;
    final list = appliances;

    return ColoredBox(
      color: KioskColors.bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 10, 28, 4),
        child: Column(children: [
          SizedBox(height: 80, child: Row(children: [
            Expanded(child: Text(_dateStr, style: const TextStyle(fontSize: 33, color: KioskColors.muted))),
            OutlinedButton.icon(key: const ValueKey('settings-entry'),
              onPressed: onSettingsGesture, icon: const Icon(Icons.settings_outlined),
              label: const Text('설정', style: TextStyle(fontSize: 33))),
            const SizedBox(width: 12),
            KioskConnectionIcons(items: connections, onOpen: onOpenConnection),
          ])),
          Expanded(child: Row(children: [
            Expanded(child: SingleChildScrollView(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_clock, style: const TextStyle(fontSize: 104, height: 1, color: Colors.white,
                  fontFeatures: [FontFeature.tabularFigures()])),
                if (env != null) Text(env, style: const TextStyle(fontSize: 33, color: KioskColors.muted)),
                OutlinedButton(onPressed: onDndGesture,
                  child: Text(dndUntil == null ? '방해 금지' : '방해 금지 · ${_dndRemaining(dndUntil!)}',
                    style: const TextStyle(fontSize: 33))),
              ],
            ))),
            const SizedBox(width: 20),
            Expanded(child: SingleChildScrollView(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(greeting, style: const TextStyle(fontSize: 33, color: Colors.white)),
                if (amb?.tip != null && amb!.tip!.text.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _TipCard(key: const ValueKey('ambient-tip'), tip: amb.tip!),
                ],
                if (amb != null && amb.hourly.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _Hours(key: const ValueKey('ambient-hours'), hours: amb.hourly.take(4).toList()),
                ],
              ],
            ))),
          ])),
          SizedBox(height: 160, child: Center(child: SingleChildScrollView(child: list == null
            ? const _StripNotice('허브와 연결되면 가전이 보여요')
            : list.isEmpty ? const _StripNotice('앱에서 가전을 추가해 주세요')
            : KioskApplianceStrip(appliances: list, running: running, attention: attention, onSelect: onSelectAppliance)))),
        ]),
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
      _ => Icons.error_outline,
    };

class _TipCard extends StatelessWidget {
  const _TipCard({super.key, required this.tip});
  final AmbientTip tip;

  @override
  Widget build(BuildContext context) {
    // 확인이 필요한 가전·위험 소리는 노란색 — 날씨는 강조색.
    final attention = tip.icon == 'attention';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: KioskColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: attention ? KioskColors.warning : KioskColors.border),
      ),
      child: Row(
        children: [
          Icon(_tipIcon(tip.icon),
              size: 30,
              color: attention ? KioskColors.warning : KioskColors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              tip.text,
              style: const TextStyle(
                  fontSize: 33, height: 1.3, color: Colors.white),
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
  const _Hours({super.key, required this.hours});
  final List<AmbientHour> hours;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          for (final h in hours)
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(h.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 33, color: KioskColors.muted)),
                  const SizedBox(height: 4),
                  Icon(_hourIcon(h.icon),
                      size: 26,
                      color: h.precip ? KioskColors.primary : KioskColors.muted),
                  const SizedBox(height: 4),
                  // 비·눈 칸은 강수확률을, 나머지는 기온을 — 색만이 아니라 숫자로.
                  Text(
                    h.precip && h.pop != null
                        ? '${h.pop}%'
                        : h.temp != null
                            ? '${h.temp}°'
                            : '',
                    style: TextStyle(
                      fontSize: 33,
                      fontWeight: h.precip ? FontWeight.w700 : FontWeight.w500,
                      color: h.precip ? Colors.white : KioskColors.muted,
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
}

