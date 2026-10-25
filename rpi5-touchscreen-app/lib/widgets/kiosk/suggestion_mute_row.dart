import 'package:flutter/material.dart';

import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'kiosk_text.dart';

/// 제안 카드 '아니요' 바로 위 한 줄 — 체크 + '이 제안 앞으로 받지 않기'(2026-10-25 계획 §3).
///
/// 줄 전체가 누르는 자리(캔버스 48 이상 — 실패널 약 98px). 체크만으로는 아무것도 보내지 않는다 — '아니요'를 눌러야
/// 서버 `reject(mute=true)`가 간다('네'는 체크를 보지 않는다). 화면 읽기에는 체크 상자 하나로 읽힌다.
class KioskSuggestionMuteRow extends StatelessWidget {
  const KioskSuggestionMuteRow({super.key, required this.checked, required this.onChanged});

  final bool checked;
  final ValueChanged<bool> onChanged;

  static const String label = '이 제안 앞으로 받지 않기';

  @override
  Widget build(BuildContext context) => Semantics(
        checked: checked,
        label: label,
        excludeSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: const ValueKey('suggestion-mute'),
            onTap: () => onChanged(!checked),
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(children: [
                // 체크 상자는 그림만 — 누름은 줄 전체가 받는다(두 번 바뀌지 않게).
                IgnorePointer(
                  child: Checkbox(
                    value: checked,
                    onChanged: (_) {},
                    activeColor: KioskColors.primary,
                    checkColor: KioskColors.onAccent,
                    side: BorderSide(color: KioskColors.muted, width: 2),
                  ),
                ),
                const SizedBox(width: KioskSpace.xs),
                Expanded(
                  child: KioskText(
                    label,
                    style: TextStyle(fontSize: KioskType.body, height: 1.2, color: KioskColors.ink),
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
}
