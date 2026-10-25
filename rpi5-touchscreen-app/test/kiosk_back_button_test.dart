// UI 평가 4차(2026-10-17): 가전 선택·내 가전(ThinQ 상세 포함) 머리의 뒤로 단추가 회색 가는 화살표뿐이라
// 1~2 m에서 잘 안 보였다 — 위쪽 아이콘에 이름을 붙인 기준과 같게 '뒤로' 글자와 테두리를 둔다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_select_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump();
}

void _expectLabeledBack(WidgetTester tester) {
  final back = find.byKey(const ValueKey('kiosk-back'));
  expect(back, findsOneWidget);
  expect(find.descendant(of: back, matching: find.text('뒤로')), findsOneWidget);
  final icon = tester.widget<Icon>(find.descendant(of: back, matching: find.byIcon(Icons.arrow_back)));
  expect(icon.color, KioskColors.ink); // 글자색 화살표(밝은 화면 10/24부터 짙은 색)
  final size = tester.getSize(back);
  expect(size.height, greaterThanOrEqualTo(52));
  expect(size.width, greaterThanOrEqualTo(88));
}

void main() {
  testWidgets('가전 선택 화면 — 뒤로 단추에 글자와 흰 화살표', (tester) async {
    var cancelled = 0;
    await _pump(
        tester,
        KioskApplianceSelectView(
          appliances: const [kMicrowaveAppliance],
          lastUsedId: null,
          onSelect: (_) {},
          onCancel: () => cancelled++,
        ));
    _expectLabeledBack(tester);
    await tester.tap(find.byKey(const ValueKey('kiosk-back')));
    expect(cancelled, 1);
    expect(find.bySemanticsLabel('처음 화면으로'), findsOneWidget);
    expect(KioskColors.muted, isNot(KioskColors.ink));
  });

  testWidgets('내 가전(수동 조작) 화면 — 뒤로 단추에 글자와 흰 화살표', (tester) async {
    var cancelled = 0;
    await _pump(
        tester,
        KioskManualView(
          appliance: kMicrowaveAppliance,
          onExecute: (_) {},
          onCancel: () => cancelled++,
        ));
    _expectLabeledBack(tester);
    await tester.tap(find.byKey(const ValueKey('kiosk-back')));
    expect(cancelled, 1);
  });
}
