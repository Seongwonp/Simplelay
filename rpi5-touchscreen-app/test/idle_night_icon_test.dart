// 밤 시간 예보의 맑음은 해가 아니라 달(외부 평가 10/16 4차 — 실패널 0시·3시에 해 아이콘이 찍혔다).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';

void main() {
  testWidgets('맑음: 밤(0시·3시)은 달, 낮(15시)은 해', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: KioskIdleView(
          now: DateTime(2026, 10, 16, 22, 30),
          connected: true,
          appliances: [kMicrowaveAppliance],
          ambient: const AmbientInfo(greeting: '편안한 밤 보내세요.', weatherSource: 'kma', hourly: [
            AmbientHour(label: '0시', icon: 'clear', temp: 16),
            AmbientHour(label: '3시', icon: 'clear', temp: 15),
            AmbientHour(label: '15시', icon: 'clear', temp: 20),
          ]),
          onSelectAppliance: (_) {},
          onOpenConnection: (_) {},
          onDndGesture: () {},
        ),
      ),
    ));
    final hours = find.byKey(const ValueKey('ambient-hours'));
    expect(find.descendant(of: hours, matching: find.byIcon(Icons.nightlight)), findsNWidgets(2));
    expect(find.descendant(of: hours, matching: find.byIcon(Icons.wb_sunny)), findsOneWidget);
    // 지금 날씨는 예보 줄 첫 칸 '지금'(사용자 요청 10/18) — 밤이면 달. 22:30의 지금 칸은 0시(90분 뒤) 값을 쓴다.
    final now = find.byKey(const ValueKey('ambient-hour-0'));
    expect(find.descendant(of: now, matching: find.text('지금')), findsOneWidget);
    expect(find.descendant(of: now, matching: find.byIcon(Icons.nightlight)), findsOneWidget);
    expect(find.byKey(const ValueKey('idle-outside')), findsNothing);
  });
}
