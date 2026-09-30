// 제안 화면 — 어느 가전을 → 무엇을 → 어떤 순서로 → 할까 말까.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

const _sug = KioskSuggestion(
  id: 's1',
  purpose: '즉석밥 데워줘',
  occurrences: 3,
  timeBand: '아침',
  steps: ['즉석밥', '시작'],
  applianceId: 'microwave',
);

const _approve = ValueKey('suggestion-approve');
const _later = ValueKey('suggestion-later');

Future<void> _pump(WidgetTester tester,
    {ApplianceMap? target, KioskSuggestion suggestion = _sug}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: KioskSuggestionView(
        suggestion: suggestion,
        target: target,
        cdRemaining: 20,
        cdTotal: 20,
        onApprove: () {},
        onReject: () {},
      ),
    ),
  ));
}

void main() {
  testWidgets('버튼은 시작과 다음에 두 개뿐 — 억제·미루기·바꾸기는 폰에 둔다', (tester) async {
    await _pump(tester, target: kMicrowaveAppliance);
    expect(tester.takeException(), isNull);
    expect(find.byType(ElevatedButton), findsOneWidget);
    expect(find.byType(OutlinedButton), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    expect(find.text('다음에'), findsOneWidget);
    expect(find.descendant(of: find.byKey(_approve), matching: find.text('시작')),
        findsOneWidget);
  });

  testWidgets('루틴 카드는 사용자가 붙인 루틴 이름을 보인다', (tester) async {
    await _pump(tester,
        target: kMicrowaveAppliance,
        suggestion: const KioskSuggestion(
          id: 'r1',
          purpose: '아침 데우기',
          occurrences: 0,
          applianceId: 'microwave',
          routineId: 'morning',
          routineName: '아침 데우기',
        ));
    expect(find.text('내 루틴 "아침 데우기"'), findsOneWidget);
  });

  testWidgets('대상 가전·질문·번호 붙은 순서·두 행동을 보여준다', (tester) async {
    await _pump(tester, target: kMicrowaveAppliance);

    expect(find.text('전자레인지'), findsOneWidget);
    expect(find.text('즉석밥 데워줘,\n지금 할까요?'), findsOneWidget);
    expect(find.text('누를 순서'), findsOneWidget);
    for (final (i, label) in [(1, '즉석밥'), (2, '시작')]) {
      expect(find.text('$i'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(ListView), matching: find.text(label)),
          findsOneWidget);
    }
    expect(find.byKey(_approve), findsOneWidget);
    expect(find.byKey(_later), findsOneWidget);
    expect(find.textContaining('AI'), findsNothing);
  });

  testWidgets('대상을 모르면 대상 줄을 그리지 않는다', (tester) async {
    await _pump(tester);

    expect(find.text('전자레인지'), findsNothing);
    expect(find.byKey(_approve), findsOneWidget);
  });

  testWidgets('대상을 모르는 제안은 실행 버튼을 잠그고 이유를 말한다', (tester) async {
    // 백로그 B10 — 서버도 대상 없는 승인을 409로 거절하므로, 눌리는
    // 버튼을 세워 두면 "눌렀는데 아무 일도 없는" 화면이 된다.
    await _pump(tester);

    final button = tester.widget<ElevatedButton>(find.byKey(_approve));
    expect(button.onPressed, isNull);
    expect(
      find.textContaining('가전을 찾을 수 없어 실행할 수 없어요'),
      findsOneWidget,
    );
    // 넘기기는 그대로 된다 — 카드에서 벗어날 길은 항상 있어야 한다.
    final reject = tester.widget<OutlinedButton>(find.byKey(_later));
    expect(reject.onPressed, isNotNull);
  });

  testWidgets('대상이 있으면 실행 버튼이 살아 있다', (tester) async {
    await _pump(tester, target: kMicrowaveAppliance);

    final button = tester.widget<ElevatedButton>(find.byKey(_approve));
    expect(button.onPressed, isNotNull);
    expect(find.textContaining('누르지 않으면 실행하지 않아요'), findsOneWidget);
  });

  testWidgets('두 버튼 모두 최소 터치 크기를 지킨다', (tester) async {
    await _pump(tester, target: kMicrowaveAppliance);
    expect(tester.getSize(find.byKey(_approve)).height,
        greaterThanOrEqualTo(48));
    expect(tester.getSize(find.byKey(_later)).height, greaterThanOrEqualTo(48));
  });

  test('서버가 준 appliance_id를 받는다', () {
    final parsed = KioskSuggestion.fromJson({
      'id': 's1',
      'purpose': '즉석밥 데워줘',
      'appliance_id': 'custom_fan',
    });
    expect(parsed.applianceId, 'custom_fan');
    expect(
      KioskSuggestion.fromJson({'id': 's2', 'purpose': 'x'}).applianceId,
      isNull,
    );
  });
}
