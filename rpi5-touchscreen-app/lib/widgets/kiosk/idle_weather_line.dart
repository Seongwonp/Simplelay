import 'package:flutter/material.dart';

import '../../models/ambient.dart';
import '../../theme/kiosk_colors.dart';
import 'idle_side_rows.dart';
import 'kiosk_text.dart';
import 'weather_icon.dart';

/// 처음 화면 오른쪽 날씨 줄(2026-10-25 계획 §2) — 머리말 없이 한 줄 `[아이콘] 18° · 강풍주의보  ›`(특보가 없으면 하늘 말).
/// 지금 칸이 없어 예보 칸을 쓸 때만 작게 '낮 12시 예보'. 아래 작은 줄은 있을 때만 — 첫 특보 안내, 없으면 날씨 안내·비 소식.
/// 줄 전체가 누르는 자리(캔버스 48 이상 — 실패널 약 98px)이고 누르면 날씨 자세히 창([onTap]). 음성으로는 읽지 않는다.
class KioskWeatherLine extends StatelessWidget {
  const KioskWeatherLine({
    super.key,
    this.now,
    this.at,
    required this.night,
    this.warning,
    this.advice,
    this.adviceIsTip = false,
    this.onTap,
  });

  final AmbientHour? now;

  /// [now]가 '지금'이 아니라 예보 칸이면 그 시각('낮 12시') — 뒤에 작게 '낮 12시 예보'.
  final String? at;
  final bool night;

  /// 가장 강한 특보(서버가 강한 것부터 보낸다). 있으면 하늘 말 대신 그 제목.
  final AmbientWarning? warning;
  final String? advice;

  /// 아래 줄이 할 일이 담긴 안내(특보·서버 날씨 안내)인가 — 그러면 흰 글자, 비 소식이면 회색.
  final bool adviceIsTip;
  final VoidCallback? onTap;

  /// 화면 읽기 말 — '날씨 자세히 보기. 18도, 맑음, 강풍주의보. 바람이 강해요…'.
  String get semanticsLabel {
    final n = now;
    final word = n == null ? '' : weatherWord(n.icon);
    final facts = [
      if (at != null) '$at 예보',
      if (n?.temp != null) '${n!.temp}도',
      if (word.isNotEmpty) word,
      if (warning case final w?) w.title,
    ].join(', ');
    return [
      if (onTap != null) '날씨 자세히 보기' else '바깥 날씨',
      if (facts.isNotEmpty) facts,
      if (advice case final a?) a,
    ].join('. ');
  }

  @override
  Widget build(BuildContext context) {
    final n = now;
    final w = warning;
    final word = n == null ? '' : weatherWord(n.icon);
    final head = <InlineSpan>[
      if (n?.temp != null) TextSpan(text: '${n!.temp}°'),
      if (w != null)
        TextSpan(text: '${n?.temp != null ? ' · ' : ''}${w.title}', style: TextStyle(color: KioskColors.warning))
      else if (word.isNotEmpty)
        TextSpan(text: '${n?.temp != null ? ' · ' : ''}$word', style: const TextStyle(fontWeight: FontWeight.w500)),
      if (at != null) TextSpan(text: ' · $at 예보', style: KioskSideRow.smallStyle.copyWith(color: KioskColors.muted)),
    ];
    final body = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      if (head.isNotEmpty)
        Row(key: ValueKey(n == null ? 'idle-weather-warning' : (at == null ? 'idle-weather-now' : 'idle-weather-forecast')), children: [
          if (n != null)
            KioskWeatherIcon(n.icon, night: night, size: 24, color: KioskColors.ink)
          else if (w != null)
            Icon(warningIcon(w.icon), size: 24, color: KioskColors.warning),
          const SizedBox(width: 6),
          Flexible(
            child: Text.rich(
              TextSpan(children: head),
              key: const ValueKey('idle-weather-head'),
              maxLines: 2,
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
    ]);
    final tap = onTap;
    if (tap == null) {
      return Semantics(container: true, label: semanticsLabel, excludeSemantics: true, child: body);
    }
    return Semantics(
      button: true,
      label: semanticsLabel,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: const ValueKey('idle-weather-tap'),
          onTap: tap,
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            // 끝의 '›' — 누르면 더 볼 수 있다는 표시(줄 전체가 누르는 자리).
            child: Row(children: [
              Expanded(child: body),
              Icon(Icons.chevron_right, key: const ValueKey('idle-weather-more'), size: 26, color: KioskColors.muted),
            ]),
          ),
        ),
      ),
    );
  }
}

/// 날씨 줄 아래 작은 안내 — 첫 특보 안내, 없으면 서버 날씨 안내. 둘 다 없으면 null(비 소식은 처음 화면이 따로 고른다).
String? weatherAdviceOf(AmbientInfo? ambient, AmbientTip? fallbackTip) {
  for (final w in ambient?.warnings ?? const <AmbientWarning>[]) {
    if (w.advice.isNotEmpty) return kioskLine(w.advice);
  }
  final tip = ambient?.weatherTip;
  if (tip != null && tip.text.isNotEmpty) return kioskLine(tip.text);
  if (fallbackTip != null && fallbackTip.text.isNotEmpty) return kioskLine(fallbackTip.text);
  return null;
}
