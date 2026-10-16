import 'package:flutter/material.dart';

import '../models/auto_rule.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// 자동 실행 허용 확인(2026-10-13) — 새 화면이 아니라 아래에서 올라오는 시트다.
///
/// 서버가 만든 조건·동작 문장을 **그대로** 보여 주고, 사용자가 허용 버튼을 눌렀을 때만 true를 돌려준다.
/// 닫거나 '취소'면 false — 아무것도 저장·실행하지 않는다.
Future<bool> showAutoRuleConfirmSheet(
  BuildContext context, {
  required String conditionText,
  required String actionText,
  String? caveat = kCookCaveat,
  // 줄을 직접 나눈다 — 한글은 글자 단위로 끊겨 '자동으/로'처럼 갈렸다(외부 평가 10/16 p06).
  String title = '이번에 실행하고\n다음부터 자동으로 할까요?',
  String confirmLabel = '허용하고 이번에도 실행',
}) async {
  final allowed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: AppText.heading),
            const SizedBox(height: 16),
            _Line(label: '조건', text: conditionText),
            const SizedBox(height: 8),
            _Line(label: '동작', text: actionText),
            const SizedBox(height: 12),
            // 근거의 한계는 허용하는 이 자리에서 말한다 — 문장은 서버가 조건 종류에 맞게 준다(2026-10-16: 가열 종료는
            // 전력 하강 판정, 시각 규칙은 허브 시계). 옛 서버는 칸이 없어 가열 종료 문장을 쓴다.
            if (caveat != null) ...[
              Text(
                caveat,
                key: const Key('auto-rule-caveat'),
                style: TextStyle(fontSize: 15, color: sheetContext.appMuted),
              ),
              const SizedBox(height: 8),
            ],
            Text(
              '버튼 누름은 매번 승인받아요. 조건·동작이 바뀌면 다시 묻고, 루틴 탭에서 언제든 끌 수 있어요.',
              style: TextStyle(fontSize: 15, color: sheetContext.appMuted),
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('auto-rule-allow'),
              onPressed: () => Navigator.pop(sheetContext, true),
              child: Text(confirmLabel),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              key: const Key('auto-rule-cancel'),
              onPressed: () => Navigator.pop(sheetContext, false),
              child: const Text('취소'),
            ),
          ],
        ),
      ),
    ),
  );
  return allowed == true;
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.text});
  final String label;
  final String text;

  @override
  Widget build(BuildContext context) => Text.rich(
        TextSpan(children: [
          TextSpan(
            text: '$label: ',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          TextSpan(text: text),
        ]),
        style: const TextStyle(fontSize: 18),
      );
}
