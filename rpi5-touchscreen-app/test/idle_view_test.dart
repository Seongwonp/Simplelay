// 대기 화면 — 멀리서 읽혀야 하는 것은 시각이 아니라
// **어느 가전을 · 지금 조작할 수 있는지 · 어떻게 시작하는지**다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';

Future<void> _pump(
  WidgetTester tester, {
  ApplianceMap? appliance,
  bool connected = true,
  bool actuatorReady = true,
}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: KioskIdleView(
        now: DateTime(2026, 9, 13, 9, 5),
        connected: connected,
        actuatorReady: actuatorReady,
        appliance: appliance,
        onTap: () {},
        onLongPress: () {},
      ),
    ),
  ));
}

void main() {
  testWidgets('가전·조작 가능·시작 방법을 말하고 시각은 보조로 둔다', (tester) async {
    await _pump(tester, appliance: kMicrowaveAppliance);

    expect(find.text('전자레인지'), findsOneWidget);
    expect(find.text('조작할 수 있어요'), findsOneWidget);
    expect(find.text('화면을 눌러 시작하세요'), findsOneWidget);
    // 시각은 날짜와 한 줄에 작게 -- 108px 시계가 아니다.
    final time = tester.widget<Text>(find.text('9월 13일 일요일 · 09:05'));
    expect(time.style!.fontSize, lessThan(30));
    // 이 키오스크는 말을 듣지 않는다. 할 수 없는 일을 권하지 않는다.
    expect(find.textContaining('말하'), findsNothing);
  });

  testWidgets('준비 안 된 가전은 이유를 말하고 조작 가능이라 하지 않는다', (tester) async {
    await _pump(
      tester,
      appliance: const ApplianceMap(
        id: 'microwave',
        name: '전자레인지',
        category: 'microwave',
        rows: 1,
        cols: 1,
        buttons: [],
        canExecute: false,
        readiness: 'needs_setup',
        readinessReasons: ['버튼 위치 보정이 아직 안 됐어요'],
      ),
    );

    expect(find.text('버튼 위치 보정이 아직 안 됐어요'), findsOneWidget);
    expect(find.text('조작할 수 있어요'), findsNothing);
    // 색만이 아니라 모양으로도 구분한다.
    expect(find.byIcon(Icons.build_outlined), findsOneWidget);
  });

  testWidgets('서버 준비 상태를 모르면 막지 않는다 — unknown은 안 됨이 아니다',
      (tester) async {
    await _pump(
      tester,
      appliance: const ApplianceMap(
        id: 'microwave',
        name: '전자레인지',
        category: 'microwave',
        rows: 1,
        cols: 1,
        buttons: [],
        canExecute: false,
      ),
    );

    expect(find.text('조작할 수 있어요'), findsOneWidget);
  });

  testWidgets('연결이 없으면 시작을 권하지 않는다', (tester) async {
    await _pump(tester, appliance: kMicrowaveAppliance, connected: false);

    expect(find.text('기기 연결이 필요해요'), findsOneWidget);
    expect(find.text('화면을 눌러 시작하세요'), findsNothing);
  });

  testWidgets('가전을 모르면 이름을 지어내지 않는다', (tester) async {
    await _pump(tester);

    expect(find.text('전자레인지'), findsNothing);
    expect(find.text('화면을 눌러 시작하세요'), findsOneWidget);
  });
}
