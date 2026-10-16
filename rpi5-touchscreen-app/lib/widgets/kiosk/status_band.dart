import 'package:flutter/material.dart';

import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'estop_banner.dart';
import 'practice_band.dart';

/// 상태 띠의 뜻(2026-10-16 디자인 규격 §1-2·§4 결정) — 색만이 아니라 아이콘·글자가 함께 간다.
enum KioskBandTone {
  /// 일반 상태 — 중립 회색.
  neutral,
  running,
  confirmed,

  /// 연습 — 청록(앰버를 쓰지 않는다).
  practice,

  /// 확인 필요 — 앰버. 채운 단추처럼 보이지 않게 옅은 면 + 줄 + 아이콘.
  attention,

  /// 실패·비상 — 빨강.
  danger,
}

/// 상태 띠 — **제안 → 실행 → 정지 대기 → 결과** 화면 맨 위, 모든 화면에서 같은 자리·같은 높이.
///
/// 평소·수동 조작·설정 화면에는 두지 않는다(비상 버튼 띠는 별도로 모든 화면 위에 붙는다 — `estop_banner.dart`).
/// 연습이면 띠 전체가 청록 연습 띠가 되고, 연습 중 확인 필요·실패가 겹치면 그 색 띠 오른쪽에 청록 연습 칸을
/// 함께 둔다 — 연습 표시는 어느 결과에서도 사라지지 않는다. 큰 글씨에서는 글자를 줄이지 않고 줄을 바꾼다.
class KioskStatusBand extends StatelessWidget {
  const KioskStatusBand({
    super.key,
    required this.tone,
    required this.icon,
    required this.label,
    this.practice = false,
    this.suppressUnderEstop = false,
  });

  /// 연습 실행의 일반 상태 — 띠 전체가 청록 연습 띠.
  const KioskStatusBand.practice({super.key})
      : tone = KioskBandTone.practice,
        icon = Icons.school_outlined,
        label = kPracticeBandText,
        practice = true,
        suppressUnderEstop = false;

  final KioskBandTone tone;
  final IconData icon;
  final String label;

  /// 연습 실행인가 — [tone]이 확인 필요·실패여도 청록 연습 칸을 함께 그린다.
  final bool practice;
  final bool suppressUnderEstop;

  /// 띠 뜻별 색(아이콘·왼쪽 줄·옅은 면).
  static Color colorOf(KioskBandTone tone) => switch (tone) {
        KioskBandTone.neutral => KioskColors.muted,
        KioskBandTone.running => KioskColors.running,
        KioskBandTone.confirmed => KioskColors.confirmed,
        KioskBandTone.practice => KioskColors.practice,
        KioskBandTone.attention => KioskColors.warning,
        KioskBandTone.danger => KioskColors.danger,
      };

  static const _text = TextStyle(
    fontSize: KioskType.body,
    fontWeight: FontWeight.w700,
    color: Colors.white,
    height: 1.25,
  );

  /// 비상 버튼 띠 아래의 얇은 띠 글자(보조 크기).
  static const _slimText = TextStyle(
    fontSize: KioskType.caption,
    fontWeight: FontWeight.w700,
    color: Colors.white,
    height: 1.2,
  );

  @override
  Widget build(BuildContext context) {
    if (suppressUnderEstop && KioskEstopScope.shownOf(context)) {
      return const SizedBox.shrink();
    }
    final color = colorOf(tone);
    // 위에 비상 버튼 띠가 있으면 얇게 — 뜻(아이콘·색·글자)은 그대로, 높이만 낮춘다(2026-10-16).
    final slim = KioskEstopScope.shownOf(context);
    final text = slim ? _slimText : _text;
    final iconSize = slim ? KioskSizes.bandSlimIcon : KioskSizes.bandIcon;
    final Widget content;
    if (tone == KioskBandTone.practice) {
      content = _PracticeMark(
          iconKey: const ValueKey('status-band-icon'),
          style: text,
          iconSize: iconSize);
    } else {
      final main = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon,
              key: const ValueKey('status-band-icon'),
              size: iconSize,
              color: color),
          const SizedBox(width: 10),
          Flexible(child: Text(label, style: text)),
        ],
      );
      content = practice
          ? Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 20,
              runSpacing: 4,
              children: [
                main,
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  decoration: BoxDecoration(
                    color: KioskColors.practice
                        .withValues(alpha: KioskSizes.bandTint),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: KioskColors.practice, width: 1.5),
                  ),
                  child: _PracticeMark(style: text, iconSize: iconSize),
                ),
              ],
            )
          : main;
    }
    return Semantics(
      container: true,
      child: Container(
        key: const ValueKey('status-band'),
        width: double.infinity,
        constraints: BoxConstraints(
            minHeight:
                slim ? KioskSizes.bandSlimHeight : KioskSizes.bandHeight),
        alignment: Alignment.centerLeft,
        padding: EdgeInsets.fromLTRB(14, slim ? 2 : 4, 14, slim ? 2 : 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: KioskSizes.bandTint),
          border: Border(
            left: BorderSide(color: color, width: KioskSizes.bandStripe),
          ),
        ),
        child: content,
      ),
    );
  }
}

/// 청록 연습 표시 — 연습 아이콘 + '연습 중 · 실제 가전에는 보내지 않아요'.
class _PracticeMark extends StatelessWidget {
  const _PracticeMark({
    this.iconKey,
    this.style = KioskStatusBand._text,
    this.iconSize = KioskSizes.bandIcon,
  });

  final Key? iconKey;
  final TextStyle style;
  final double iconSize;

  @override
  Widget build(BuildContext context) => Row(
        key: const ValueKey('practice-band'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.school_outlined,
              key: iconKey, size: iconSize, color: KioskColors.practice),
          const SizedBox(width: 10),
          Flexible(
            child: Text(kPracticeBandText, style: style),
          ),
        ],
      );
}
