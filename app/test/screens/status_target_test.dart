// 실행 화면은 **그 실행이 대상으로 삼은 가전**의 버튼 이름을 쓴다.
//
// 지금 고른 가전으로 읽으면, 실행 중에 다른 가전을 고른 순간 화면이 틀린
// 버튼 이름을 말한다. 대상은 실행이 정하지, 화면이 정하지 않는다.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/screens/status_screen.dart';

import '../helpers/test_helpers.dart';

final _dishwasher = ApplianceMap(
  id: 'custom_dish',
  name: '식기세척기',
  category: ApplianceCategory.other,
  rows: 1,
  cols: 2,
  buttons: const [
    ApplianceButton(id: 'custom_btn_1', label: '표준 세척', x: 0, y: 0),
    ApplianceButton(id: 'custom_btn_2', label: '헹굼', x: 1, y: 0),
  ],
  isCustom: true,
);

ExecutionStatus _running({String? applianceId}) => ExecutionStatus(
      phase: ExecutionPhase.running,
      label: '설거지',
      sequenceId: 's1',
      steps: const ['custom_btn_1', 'custom_btn_2'],
      completedSteps: 1,
      applianceId: applianceId,
    );

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('대상 가전의 버튼 이름으로 단계를 읽는다', (tester) async {
    _tall(tester);
    await tester.pumpWidget(buildScreen(
      const StatusScreen(),
      executionStatus: _running(applianceId: 'custom_dish'),
      overrides: installedOverrides([_dishwasher]),
    ));
    await tester.pump();

    expect(find.text('표준 세척'), findsOneWidget);
    expect(find.text('헹굼'), findsOneWidget);
    // 코드가 그대로 새어 나오지 않는다.
    expect(find.text('custom_btn_1'), findsNothing);
  });

  testWidgets('실행 중에 다른 가전을 골라도 대상은 바뀌지 않는다', (tester) async {
    // 이게 이 화면의 계약이다. 예전 구조라면 '지금 고른 가전'이 이겨서
    // 식기세척기를 누르는 중에 전자레인지 버튼 이름이 떴다.
    _tall(tester);
    await tester.pumpWidget(buildScreen(
      const StatusScreen(),
      executionStatus: _running(applianceId: 'custom_dish'),
      overrides: installedOverrides(
        [_dishwasher, kTestAppliance],
        selected: kTestAppliance, // 사용자는 전자레인지를 보고 있다
      ),
    ));
    await tester.pump();

    expect(find.text('표준 세척'), findsOneWidget);
  });

  testWidgets('대상을 모르면 지어내지 않는다 — 코드를 그대로 둔다', (tester) async {
    // 구버전 서버이거나 대상 없이 도는 구성. 지금 고른 가전으로 메우면
    // 화면이 누르지도 않은 버튼 이름을 말하게 된다.
    _tall(tester);
    await tester.pumpWidget(buildScreen(
      const StatusScreen(),
      executionStatus: _running(),
      overrides: installedOverrides([_dishwasher]),
    ));
    await tester.pump();

    expect(find.text('표준 세척'), findsNothing);
    expect(find.text('custom_btn_1'), findsOneWidget);
  });
}
