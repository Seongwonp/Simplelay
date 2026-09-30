// G5(화면) — /appliances의 control_path로 ThinQ 가전을 가른다(2026-09-29).
// 가전 선택 화면은 ThinQ 배지를 달고, ThinQ 가전에는 버튼판을 그리지 않는다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_select_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/route_badge.dart';

final _purifier = applianceFromServerJson({
  'id': 'air_purifier',
  'name': '공기청정기(모의)',
  'category': 'other',
  'rows': 0,
  'cols': 0,
  'buttons': <dynamic>[],
  'control_path': 'thinq',
  'can_execute': true,
  'readiness': 'operable',
});

Future<void> _pump(WidgetTester tester, Widget view) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: view)));
}

void main() {
  test('control_path가 없으면 물리, thinq면 ThinQ 가전이다', () {
    expect(_purifier.isThinq, isTrue);
    final legacy = applianceFromServerJson({
      'id': 'microwave',
      'name': '전자레인지',
      'category': 'microwave',
      'rows': 1,
      'cols': 1,
      'buttons': [
        {'id': 'BT-08', 'label': '즉석밥', 'x': 0, 'y': 0},
      ],
    });
    expect(legacy.controlPath, 'physical');
    expect(legacy.isThinq, isFalse);
  });

  testWidgets('가전 선택: ThinQ 가전에만 ThinQ 배지가 붙는다', (tester) async {
    ApplianceMap? picked;
    await _pump(
      tester,
      KioskApplianceSelectView(
        appliances: [kMicrowaveAppliance, _purifier],
        lastUsedId: null,
        onSelect: (a) => picked = a,
        onCancel: () {},
      ),
    );

    expect(find.text('공기청정기(모의)'), findsOneWidget);
    expect(find.widgetWithText(KioskRouteBadge, 'ThinQ'), findsOneWidget);
    expect(find.byType(KioskRouteBadge), findsOneWidget);
    await tester.tap(find.text('공기청정기(모의)'));
    expect(picked?.id, 'air_purifier');
  });

  testWidgets('ThinQ 가전은 버튼판 없이 경로와 안내만 보인다', (tester) async {
    await _pump(
      tester,
      KioskManualView(
        appliance: _purifier,
        onExecute: (_) => fail('ThinQ 가전에는 누를 버튼이 없다'),
        onCancel: () {},
      ),
    );

    expect(find.text('내 공기청정기(모의)'), findsOneWidget);
    expect(find.widgetWithText(KioskRouteBadge, 'ThinQ'), findsOneWidget);
    expect(find.textContaining('누를 버튼이 없어요'), findsOneWidget);
    expect(find.textContaining('버튼 누르기'), findsNothing);
  });

  testWidgets('물리 가전의 조작판은 종전대로 배지 없이 버튼을 그린다', (tester) async {
    await _pump(
      tester,
      KioskManualView(
        appliance: kMicrowaveAppliance,
        onExecute: (_) {},
        onCancel: () {},
      ),
    );

    expect(find.byType(KioskRouteBadge), findsNothing);
    expect(find.text('즉석밥'), findsOneWidget);
  });
}
