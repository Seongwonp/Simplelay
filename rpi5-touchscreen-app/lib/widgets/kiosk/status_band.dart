import 'package:flutter/material.dart';

import 'kiosk_text.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'estop_banner.dart';
import 'practice_band.dart';

/// 결과 띠 말은 두 가지뿐(평가 3차 10/18) — 실제로 확인한 성공만 [kBandDone], 그 밖의 모름·주의·실패는 [kBandCheck].
const kBandDone = '됐어요';
const kBandCheck = '확인 필요';

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
/// 연습이면 띠 전체가 청록 연습 띠가 되고, 연습 중 확인 필요·실패가 겹치면 그 색 띠 오른쪽에 청록 연습 표시(아이콘 + 글자,
/// 테두리 칩 없이 — 평가 14차 10/18)를 함께 둔다 — 연습 표시는 어느 결과에서도 사라지지 않는다. 큰 글씨에서는 글자를 줄이지 않고 줄을 바꾼다.
class KioskStatusBand extends StatelessWidget {
  const KioskStatusBand({
    super.key,
    required this.tone,
    required this.icon,
    required this.label,
    this.practice = false,
    this.suppressUnderEstop = false,
    this.detail,
    this.detailIcon,
  });

  /// 연습 실행의 일반 상태 — 띠 전체가 청록 연습 띠.
  const KioskStatusBand.practice({super.key, this.detail, this.detailIcon})
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

  /// 띠 오른쪽의 무엇을 하는 중인가(가전·할 일, 화면 구조 개편 10/18) — 실행 화면 왼쪽 글을 상태·진행·한 줄로
  /// 줄이려고 위 띠로 올렸다. 좁으면 다음 줄로 내려간다(자르지 않는다).
  final String? detail;
  final IconData? detailIcon;

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
          // 어절 단위로 줄을 바꾼다(평가 4차 10/18 — 실패널 글꼴이 넓어 낱말 가운데서 끊길 수 있다).
          Flexible(child: KioskText(label, style: text)),
        ],
      );
      content = practice
          ? Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 20,
              runSpacing: 4,
              children: [
                main,
                // 띠 안 글자로(평가 14차 10/18 — 띠 안에 또 테두리 칩을 두니 장식이 겹쳤다). 상태 말과 가는 세로 줄로
                // 나눈다(무엇을 하는지 줄과 같은 꼴). 청록 연습 아이콘·말은 그대로 남는다.
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                        width: 2,
                        height: iconSize,
                        color: Colors.white.withValues(alpha: 0.25)),
                    const SizedBox(width: KioskSpace.md),
                    Flexible(child: _PracticeMark(style: text, iconSize: iconSize)),
                  ],
                ),
              ],
            )
          : main;
    }
    final detail = this.detail;
    final Widget body = detail == null || detail.isEmpty
        ? content
        : Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: KioskSpace.md,
            runSpacing: 4,
            children: [
              content,
              Row(
                key: const ValueKey('status-band-detail'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 상태 말과 무엇을 하는지 사이 가는 세로 줄 — 가운뎃점으로 잇지 않는다.
                  Container(
                      width: 2,
                      height: iconSize,
                      color: Colors.white.withValues(alpha: 0.25)),
                  const SizedBox(width: KioskSpace.md),
                  if (detailIcon != null) ...[
                    Icon(detailIcon, size: iconSize, color: KioskColors.muted),
                    const SizedBox(width: KioskSpace.xs),
                  ],
                  Flexible(
                    child: KioskText(detail,
                        style: text.copyWith(
                            fontWeight: FontWeight.w500,
                            color: Colors.white.withValues(alpha: 0.85))),
                  ),
                ],
              ),
            ],
          );
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
        child: body,
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
            child: KioskText(kPracticeBandText, style: style),
          ),
        ],
      );
}
