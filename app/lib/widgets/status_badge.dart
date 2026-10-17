import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

/// 배지의 색 갈래. **초록(확인)은 실제로 확인했을 때만** 쓴다(안전 계약 — 확인 수준을 높여 보이지 않는다).
enum BadgeTone {
  /// 중립(회색) — 보냄·연습·알림만 등.
  neutral,

  /// 강조(주 행동 색) — 자동 켜짐.
  accent,

  /// 실제로 확인한 결과 — 됐어요.
  confirmed,

  /// 몰라요·봐 주세요·다시 허락 필요.
  attention,

  /// 못 했어요·멈춤.
  danger,
}

/// 상태 배지 한 모양(UI 개편안 §4 공통) — 아이콘 + 짧은 말 + 색. 색만으로 말하지 않는다.
class StatusBadge extends StatelessWidget {
  const StatusBadge({
    required this.icon,
    required this.label,
    this.tone = BadgeTone.neutral,
    super.key,
  });

  final IconData icon;
  final String label;
  final BadgeTone tone;

  Color _color(BuildContext context) => switch (tone) {
        BadgeTone.neutral => context.appMuted,
        BadgeTone.accent => context.appPrimary,
        BadgeTone.confirmed => context.appConfirmed,
        BadgeTone.attention => context.appWarning,
        BadgeTone.danger => context.appDanger,
      };

  @override
  Widget build(BuildContext context) {
    final color = _color(context);
    // 회색 배지의 **글자**는 본문 잉크색 — 회색 글자에 회색 면이면 보조 글씨 목표(7:1)에 못 미쳤다
    // (평가 3차 10/18 '연습' 배지, 6.7:1). 아이콘과 면은 회색 그대로라 다른 갈래와 섞이지 않는다.
    final ink = tone == BadgeTone.neutral ? context.appInk : color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: AppSpace.xs),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: AppSpace.xs),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                  fontSize: AppFont.caption, fontWeight: FontWeight.w600, color: ink),
            ),
          ),
        ],
      ),
    );
  }
}
