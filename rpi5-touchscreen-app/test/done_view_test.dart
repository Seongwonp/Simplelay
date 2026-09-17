// 완료 화면 — 끝낸 것은 버튼 조작이다. 무엇을·어느 가전에·어떻게 확인했는지
// 말하고, 자동으로 돌아간다는 사실을 글자로도 알린다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget view, {
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(body: view),
    ),
  ));
}

void main() {
  testWidgets('성공: 버튼 조작을 마쳤어요·대상·한 일·확인 방법·자동 복귀·처음으로',
      (tester) async {
    var dismissed = 0;
    await _pump(
      tester,
      KioskDoneView(
        success: true,
        label: '즉석밥 데워줘',
        target: kMicrowaveAppliance,
        onDismiss: () => dismissed++,
      ),
    );

    expect(find.text('버튼 조작을 마쳤어요'), findsOneWidget);
    expect(find.text('전자레인지'), findsOneWidget);
    expect(find.text('즉석밥 데워줘'), findsOneWidget);
    expect(find.text('버튼 눌림을 모두 확인했어요'), findsOneWidget);
    expect(find.text('잠시 후 처음 화면으로 돌아가요'), findsOneWidget);
    // 가전이 조리·세탁을 끝냈다고 말하지 않는다.
    expect(find.textContaining('완료되었'), findsNothing);

    await tester.tap(find.text('처음으로'));
    expect(dismissed, 1);
  });

  testWidgets('실패는 자동으로 돌아간다고 말하지 않고 다음 행동을 준다', (tester) async {
    await _pump(
      tester,
      KioskDoneView(
        success: false,
        label: '즉석밥 데워줘',
        onRetry: () {},
        onManual: () {},
        onDismiss: () {},
      ),
    );

    expect(find.text('멈췄어요'), findsOneWidget);
    expect(find.text('다시 시도'), findsOneWidget);
    expect(find.text('버튼으로 조작'), findsOneWidget);
    expect(find.text('잠시 후 처음 화면으로 돌아가요'), findsNothing);
  });

  testWidgets('큰 글씨에서도 넘치지 않는다', (tester) async {
    await _pump(
      tester,
      KioskDoneView(
        success: true,
        label: '냉동 만두 데워서 라면이랑 같이 먹을 준비',
        target: kMicrowaveAppliance,
        onDismiss: () {},
      ),
      textScale: 1.22,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('처음으로'), findsOneWidget);
  });
}
