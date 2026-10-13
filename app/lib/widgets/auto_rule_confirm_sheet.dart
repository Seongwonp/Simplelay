import 'package:flutter/material.dart';

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
  String title = '이번에 실행하고, 다음부터 자동으로 실행할까요?',
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
            // 서버 조건 문장은 짧게("○○가 멈추면") 바뀌었다 — 근거의 한계는 허용하는 이 자리에서만 말한다
            // (자동 실행 조건은 전력 하강 판정 하나뿐, 서버 CONDITION_BASIS=ct_power_end, 2026-10-14).
            Text(
              '멈춤은 전력이 줄어든 것으로 판단해요. 조리 완료가 아닐 수 있어요.',
              key: const Key('auto-rule-caveat'),
              style: TextStyle(fontSize: 15, color: sheetContext.appMuted),
            ),
            const SizedBox(height: 8),
            Text(
              '이 조건과 동작일 때만 자동으로 해요. 버튼을 누르는 조리는 매번 승인을 받아요. '
              '조건이나 동작이 바뀌면 다시 물어봐요. 루틴 탭에서 언제든 끌 수 있어요.',
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
