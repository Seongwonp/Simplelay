// 자동 실행 허용 시트의 말(첫 사용자 검토 10/19 #18) — '다음부터 자동으로'를 허락하는 자리에 '버튼 누르기는 매번 허락을
// 받아요'만 있어 무엇을 허락하는지 헷갈렸다. 허락은 적힌 일에만 쓰이고, 버튼 누르기는 본체가 자동 규칙으로 받지 않는다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/widgets/auto_rule_confirm_sheet.dart';

void main() {
  testWidgets('허락이 적힌 일에만 쓰이고 버튼 누르기는 매번 묻는다고 말한다', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAutoRuleConfirmSheet(context,
                conditionText: '공기가 나쁘면', actionText: '공기청정기 강풍', caveat: null),
            child: const Text('열기'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();

    expect(find.text('이 허락은 위에 적은 일에만 써요. 가전 버튼을 누르는 일은 자동으로 하지 않고 매번 물어봐요. '
        '루틴 화면에서 언제든 끌 수 있어요.'), findsOneWidget);
    expect(find.text('버튼 누르기는 매번 허락을 받아요. 루틴 화면에서 언제든 끌 수 있어요.'), findsNothing);
  });
}
