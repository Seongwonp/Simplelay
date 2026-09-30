// 평소 화면(UI 확정 2026-09-30 §3-1) — 집에 붙은 시계처럼. 위젯 단위로 본다.
// 화면 전체의 흐름(서버 값·모달·줄 넘기기)은 kiosk_states_test.dart에 있다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';

Future<void> _pump(
  WidgetTester tester, {
  List<ApplianceMap>? appliances = const [kMicrowaveAppliance],
  AmbientInfo? ambient,
  DateTime? dndUntil,
  double? temperature,
  double? humidity,
  DateTime? now,
}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: KioskIdleView(
        now: now ?? DateTime(2026, 9, 13, 9, 5),
        connected: true,
        ambient: ambient,
        appliances: appliances,
        dndUntil: dndUntil,
        temperature: temperature,
        humidity: humidity,
        onSelectAppliance: (_) {},
        onOpenConnection: (_) {},
        onDndGesture: () {},
      ),
    ),
  ));
}

void main() {
  testWidgets('날짜·큰 시계·실내 온습도를 보인다', (tester) async {
    await _pump(tester, temperature: 23.4, humidity: 58);

    expect(find.text('9월 13일 일요일'), findsOneWidget);
    final clock = tester.widget<Text>(find.text('9:05'));
    expect(clock.style!.fontSize, greaterThan(80));
    expect(find.text('실내 23° · 습도 58%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('실내 센서 값이 없으면 온습도 줄을 지어내지 않는다', (tester) async {
    await _pump(tester);
    expect(find.textContaining('실내'), findsNothing);
  });

  testWidgets('허브에 못 닿으면 인사말만 — 서버와 같은 시간대 규칙', (tester) async {
    await _pump(tester, now: DateTime(2026, 9, 13, 19, 0));
    expect(find.text('편안한 저녁 보내세요.'), findsOneWidget);
    expect(KioskIdleView.localGreeting(DateTime(2026, 1, 1, 7)), '좋은 아침이에요.');
    expect(KioskIdleView.localGreeting(DateTime(2026, 1, 1, 13)), '좋은 오후예요.');
    expect(KioskIdleView.localGreeting(DateTime(2026, 1, 1, 23)), '편안한 밤 보내세요.');
  });

  testWidgets('설정을 여는 방법을 글자로 말한다', (tester) async {
    // 톱니바퀴만 있으면 짧게 눌러 보고 안 열리면 고장으로 여긴다.
    await _pump(tester);
    expect(find.text('설정 · 길게 누르기'), findsOneWidget);
  });

  testWidgets('서버 목록을 못 봤으면 가전을 세우지 않는다', (tester) async {
    await _pump(tester, appliances: null);
    expect(find.text('전자레인지'), findsNothing);
    expect(find.text('허브와 연결되면 가전이 보여요'), findsOneWidget);
  });

  testWidgets('방해 금지 중이면 남은 시간을 날짜 옆에 말한다', (tester) async {
    await _pump(tester, dndUntil: DateTime(2026, 9, 13, 10, 5));
    expect(find.text('방해 금지 · 1시간'), findsOneWidget);
  });

  testWidgets('이 키오스크는 말을 듣지 않는다 — 할 수 없는 일을 권하지 않는다', (tester) async {
    await _pump(tester,
        ambient: const AmbientInfo(greeting: '좋은 아침이에요.'));
    expect(find.textContaining('말하'), findsNothing);
  });
}
