// 제안 화면 — 어느 가전을 → 무엇을 → 어떤 순서로 → 할까 말까.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

const _sug = KioskSuggestion(
  id: 's1',
  purpose: '우유 데워줘',
  occurrences: 3,
  timeBand: '아침',
  steps: ['해동', '시간 90초', '시작'],
  applianceId: 'microwave',
);

Future<void> _pump(WidgetTester tester, {ApplianceMap? target}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: KioskSuggestionView(
        suggestion: _sug,
        target: target,
        cdRemaining: 20,
        cdTotal: 20,
        onApprove: () {},
        onReject: () {},
        onRejectMute: () {},
      ),
    ),
  ));
}

void main() {
  testWidgets('대상 가전·질문·번호 붙은 순서·두 행동을 보여준다', (tester) async {
    await _pump(tester, target: kMicrowaveAppliance);

    expect(find.text('전자레인지'), findsOneWidget);
    expect(find.text('우유 데워줘, 지금 할까요?'), findsOneWidget);
    expect(find.text('누를 순서'), findsOneWidget);
    for (final (i, label) in [(1, '해동'), (2, '시간 90초'), (3, '시작')]) {
      expect(find.text('$i'), findsOneWidget);
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('지금 실행'), findsOneWidget);
    expect(find.text('이번만 넘기기'), findsOneWidget);
    expect(find.textContaining('AI'), findsNothing);
  });

  testWidgets('대상을 모르면 대상 줄을 그리지 않는다', (tester) async {
    await _pump(tester);

    expect(find.text('전자레인지'), findsNothing);
    expect(find.text('지금 실행'), findsOneWidget);
  });

  testWidgets('다시 받지 않기도 최소 터치 크기를 지킨다', (tester) async {
    await _pump(tester, target: kMicrowaveAppliance);

    final size = tester.getSize(find.ancestor(
      of: find.text('이 제안 다시 받지 않기'),
      matching: find.byType(TextButton),
    ));
    expect(size.height, greaterThanOrEqualTo(48));
  });

  test('서버가 준 appliance_id를 받는다', () {
    final parsed = KioskSuggestion.fromJson({
      'id': 's1',
      'purpose': '우유 데워줘',
      'appliance_id': 'custom_fan',
    });
    expect(parsed.applianceId, 'custom_fan');
    expect(
      KioskSuggestion.fromJson({'id': 's2', 'purpose': 'x'}).applianceId,
      isNull,
    );
  });
}
