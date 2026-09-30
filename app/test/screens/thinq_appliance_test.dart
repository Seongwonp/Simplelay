// G5(화면) — /appliances의 control_path로 ThinQ 가전을 가른다(2026-09-29).
// ThinQ 가전에는 누를 버튼이 없다: 배지로 경로를 말하고, 버튼판·사진 채우기를
// 내걸지 않는다. 물리 가전은 종전과 같다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/appliance_detail_screen.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/manual_control_screen.dart';
import 'package:simplelay/widgets/route_badge.dart';

import '../helpers/test_helpers.dart';

const _purifier = ApplianceMap(
  id: 'air_purifier',
  name: '공기청정기(모의)',
  category: ApplianceCategory.other,
  rows: 0,
  cols: 0,
  buttons: [],
  controlPath: 'thinq',
  readiness: 'operable',
  readinessKnown: true,
);

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  test('control_path가 없으면 물리 경로, thinq면 ThinQ 가전이고 BLE로 내보내지 않는다', () {
    final base = <String, dynamic>{
      'id': 'x',
      'name': '가전',
      'category': 'other',
      'rows': 0,
      'cols': 0,
      'buttons': <dynamic>[],
      'is_custom': false,
      'can_execute': true,
    };
    final legacy = ApplianceMap.fromJson(base);
    expect(legacy.controlPath, 'physical');
    expect(legacy.isThinq, isFalse);

    final thinq = ApplianceMap.fromJson({...base, 'control_path': 'thinq'});
    expect(thinq.isThinq, isTrue);
    // 누를 버튼이 없는 가전을 BLE 릴레이로 보내지 않는다.
    expect(thinq.mayDispatchWithoutServer, isFalse);
  });

  testWidgets('홈: ThinQ 가전은 배지를 달고 버튼 조작·사진 추가를 내걸지 않는다',
      (tester) async {
    _tall(tester);
    await tester.pumpWidget(buildScreen(
      const HomeScreen(),
      overrides: [
        ...connectedOverrides(),
        ...installedOverrides([_purifier]),
        rpiServerOverride(RpiConnectionState.connected),
      ],
    ));
    await tester.pump();

    expect(find.text(_purifier.name), findsOneWidget);
    expect(find.widgetWithText(RouteBadge, 'ThinQ'), findsOneWidget);
    expect(find.text('버튼으로 조작'), findsNothing);
    expect(find.text('가전 사진 추가'), findsNothing);
  });

  testWidgets('홈: 물리 가전은 배지 없이 카드만 둔다(누르기는 상세에서)', (tester) async {
    _tall(tester);
    await tester.pumpWidget(buildScreen(
      const HomeScreen(),
      overrides: [
        ...connectedOverrides(),
        ...installedOverrides([kTestAppliance]),
        rpiServerOverride(RpiConnectionState.connected),
      ],
    ));
    await tester.pump();

    expect(find.byType(RouteBadge), findsNothing);
    expect(find.text(kTestAppliance.name), findsOneWidget);
  });

  testWidgets('가전 상세: ThinQ 가전은 버튼판·루틴 녹화 없이 안내만 보인다',
      (tester) async {
    _tall(tester);
    await tester.pumpWidget(buildScreen(
      const ApplianceDetailScreen(applianceId: 'air_purifier'),
      overrides: [
        ...connectedOverrides(),
        ...installedOverrides([_purifier]),
      ],
    ));
    await tester.pump();

    expect(find.widgetWithText(RouteBadge, 'ThinQ'), findsOneWidget);
    expect(find.text('루틴 녹화'), findsNothing);
    expect(find.text('버튼판으로 하나씩 누르기'), findsNothing);
    expect(find.textContaining('누를 버튼이 없는 ThinQ 가전'), findsOneWidget);
  });

  testWidgets('버튼 조작 화면: ThinQ 가전은 버튼판 없이 배지와 안내만 보인다',
      (tester) async {
    _tall(tester);
    await tester.pumpWidget(buildScreen(
      const ManualControlScreen(),
      overrides: installedOverrides([_purifier]),
    ));
    await tester.pump();

    expect(find.widgetWithText(RouteBadge, 'ThinQ'), findsOneWidget);
    expect(find.textContaining('누를 버튼이 없어요'), findsOneWidget);
    expect(find.textContaining('누르면 실제 가전 버튼이 눌려요'), findsNothing);
    // 서버 주소가 없다는 안내(버튼 실행용)로 가리지 않는다.
    expect(find.textContaining('설정'), findsNothing);
  });
}
