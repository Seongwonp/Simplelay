import 'package:flutter/material.dart';

import '../../models/ambient.dart';
import '../../models/kiosk_time.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'idle_top.dart';
import 'kiosk_text.dart';
import 'weather_icon.dart';

/// 날씨 자세히 창(2026-10-25 계획 §2) — 처음 화면 날씨 줄을 누르면 연다. 메뉴·연결 창과 같은 큰 창([KioskIdleSheet]):
/// 어두운 막 위 카드, '닫기' 하나, 바깥을 눌러도 닫힌다. 아래 탭 숨김·화면 읽기 이름은 띄우는 쪽(처음 화면 창 껍데기)이 한다.
///
/// 순서: 지금 날씨(아이콘·기온·하늘) → 오늘 최고·최저 → 예보 4칸(시각·아이콘·기온·강수확률) → 특보와 안내 → 예보 받은 시각.
/// 값이 없는 칸은 두지 않는다(지어내지 않는다). 음성으로 읽지 않는다.
class KioskWeatherDetailSheet extends StatelessWidget {
  const KioskWeatherDetailSheet({
    super.key,
    required this.ambient,
    required this.onClose,
    this.current,
    this.currentAt,
    this.night = false,
  });

  final AmbientInfo ambient;
  final VoidCallback onClose;

  /// 처음 화면 날씨 줄과 같은 칸 — 서버 '지금', 없으면 가장 가까운 예보 칸([currentAt]이 그 시각).
  final AmbientHour? current;
  final String? currentAt;
  final bool night;

  static const String title = '날씨';

  /// 예보 받은 시각 — '오후 3시 5분에 받은 예보'. 본체는 UTC(+00:00)로 보낸다 — 한국 시각으로 바꿔 쓴다(10/25 실패널
  /// 점검: 오전 11시 10분을 '오전 2시 10분'으로 보였다). 시간대가 없으면 원문 시·분 그대로. 모르면 null.
  static String? fetchedLine(String? fetchedAt) {
    if (fetchedAt == null) return null;
    final parsed = DateTime.tryParse(fetchedAt);
    if (parsed == null) return null;
    final hasZone = RegExp(r'(Z|[+-]\d{2}:?\d{2})$').hasMatch(fetchedAt.trim());
    final at = hasZone ? parsed.toUtc().add(const Duration(hours: 9)) : parsed;
    return '${spokenTime(at.hour, at.minute)}에 받은 예보';
  }

  @override
  Widget build(BuildContext context) {
    final n = current;
    final word = n == null ? '' : weatherWord(n.icon);
    final hours = [
      for (final h in ambient.hourly.where((h) => !identical(h, n)))
        if (h.temp != null || h.icon.isNotEmpty) h,
    ].take(4).toList(growable: false);
    final today = ambient.today;
    final fetched = fetchedLine(ambient.fetchedAt);
    final muted = TextStyle(fontSize: KioskType.caption, height: 1.25, color: KioskColors.muted);
    final body = TextStyle(fontSize: KioskType.body, height: 1.25, color: KioskColors.ink);
    return KioskIdleSheet(
      key: const ValueKey('weather-detail'),
      title: title,
      onClose: onClose,
      children: [
        if (n != null)
          Semantics(
            container: true,
            excludeSemantics: true,
            label: [
              currentAt != null ? '$currentAt 예보' : '지금',
              if (n.temp != null) '${n.temp}도',
              if (word.isNotEmpty) word,
            ].join(', '),
            child: Row(key: const ValueKey('weather-detail-now'), children: [
              KioskWeatherIcon(n.icon, night: night, size: 44, color: KioskColors.ink),
              const SizedBox(width: KioskSpace.sm),
              Flexible(
                child: Text.rich(
                  TextSpan(children: [
                    if (n.temp != null) TextSpan(text: '${n.temp}°'),
                    if (word.isNotEmpty)
                      TextSpan(
                          text: '${n.temp != null ? ' ' : ''}$word',
                          style: const TextStyle(fontSize: KioskType.status, fontWeight: FontWeight.w600)),
                    TextSpan(
                        text: currentAt != null ? '  $currentAt 예보' : '  지금',
                        style: muted.copyWith(fontWeight: FontWeight.w400)),
                  ]),
                  style: TextStyle(
                      fontSize: KioskType.key, height: 1.15, fontWeight: FontWeight.w800, color: KioskColors.ink),
                ),
              ),
            ]),
          ),
        if (today != null) ...[
          const SizedBox(height: KioskSpace.xs),
          Text('오늘 최고 ${today.high}° · 최저 ${today.low}°',
              key: const ValueKey('weather-detail-today'),
              semanticsLabel: '오늘 최고 ${today.high}도, 최저 ${today.low}도',
              style: body),
        ],
        // 바깥 미세먼지(에어코리아, 2026-10-26) — 가까운 측정소의 지금 등급. 모르면 줄이 없다.
        if (ambient.outdoorAirLine case final airLine?) ...[
          const SizedBox(height: KioskSpace.xs),
          Text(airLine, key: const ValueKey('weather-detail-outdoor-air'), style: body),
        ],
        if (hours.isNotEmpty) ...[
          const SizedBox(height: KioskSpace.sm),
          Row(key: const ValueKey('weather-detail-hours'), crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final h in hours) Expanded(child: _HourCell(h)),
            // 칸 수가 모자라도 칸 폭은 4칸 기준(칸이 늘어나 보이지 않게).
            for (var i = hours.length; i < 4; i++) const Expanded(child: SizedBox.shrink()),
          ]),
        ],
        for (final w in ambient.warnings) ...[
          const SizedBox(height: KioskSpace.sm),
          _WarningRow(w),
        ],
        if (fetched != null || ambient.stale) ...[
          const SizedBox(height: KioskSpace.sm),
          Text(
            [
              if (fetched != null) fetched,
              // 새 예보를 받지 못해 지난 값을 보인다는 사실만(값은 그대로 보인다).
              if (ambient.stale) '새 예보를 받지 못해 지난 예보예요',
            ].join(' · '),
            key: const ValueKey('weather-detail-fetched'),
            style: muted,
          ),
        ],
      ],
    );
  }
}

/// 예보 한 칸 — 시각 · 아이콘 · 기온 · 강수확률(알 때만).
class _HourCell extends StatelessWidget {
  const _HourCell(this.hour);
  final AmbientHour hour;

  @override
  Widget build(BuildContext context) {
    final label = hourLabel12(hour.label);
    final word = weatherWord(hour.icon);
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: [
        label,
        if (hour.temp != null) '${hour.temp}도',
        if (word.isNotEmpty) word,
        if (hour.pop != null) '강수확률 ${hour.pop}퍼센트',
      ].join(', '),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(label,
            maxLines: 2,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: KioskType.caption, height: 1.2, color: KioskColors.muted)),
        const SizedBox(height: 4),
        KioskWeatherIcon(hour.icon, night: isNightHour(hour.slotHour), size: 30, color: KioskColors.ink),
        const SizedBox(height: 4),
        if (hour.temp != null)
          Text('${hour.temp}°',
              style: TextStyle(fontSize: KioskType.body, fontWeight: FontWeight.w700, color: KioskColors.ink)),
        if (hour.pop != null)
          Text('강수 ${hour.pop}%',
              maxLines: 1,
              style: TextStyle(
                  fontSize: KioskType.caption,
                  color: hour.precip ? KioskColors.primary : KioskColors.muted,
                  fontWeight: hour.precip ? FontWeight.w700 : null)),
      ]),
    );
  }
}

/// 특보 한 건 — 아이콘 · 제목(주의색) · 아래 안내(서버 말 그대로).
class _WarningRow extends StatelessWidget {
  const _WarningRow(this.warning);
  final AmbientWarning warning;

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        excludeSemantics: true,
        label: [warning.title, if (warning.advice.isNotEmpty) warning.advice].join('. '),
        child: Row(key: const ValueKey('weather-detail-warning'), crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(warningIcon(warning.icon), size: 26, color: KioskColors.warning),
          ),
          const SizedBox(width: KioskSpace.xs),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(warning.title,
                  style: TextStyle(fontSize: KioskType.body, fontWeight: FontWeight.w700, color: KioskColors.warning)),
              if (warning.advice.isNotEmpty)
                KioskText(warning.advice,
                    style: TextStyle(fontSize: KioskType.body, height: 1.25, color: KioskColors.ink)),
            ]),
          ),
        ]),
      );
}
