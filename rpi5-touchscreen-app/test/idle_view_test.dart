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
  VoidCallback? onDnd,
  VoidCallback? onSettings,
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
        onDndGesture: onDnd ?? () {},
        onSettingsGesture: onSettings,
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
    // 온도·습도는 두 조각 — 큰 글씨에서 조각 사이에서만 줄을 바꾸고 '실내'를 빼지 않는다(평가 4차 10/18).
    expect(find.text('실내 23°'), findsOneWidget);
    expect(find.text(' · 습도 58%'), findsOneWidget);
    // 시계는 12시간제 + 오전/오후(평가 4차 10/18).
    expect(find.text('오전'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('루틴 안내는 경고가 아니라 알림 아이콘으로 안내 한 줄에 보인다', (tester) async {
    // 시연 v3 갭 S5(2026-10-06) — 서버 /ambient tip kind=routine, icon=notice.
    await _pump(tester,
        ambient: const AmbientInfo(
          greeting: '좋은 아침이에요.',
          tip: AmbientTip(kind: 'routine', text: '약 드실 시간이에요', icon: 'notice'),
        ));
    expect(find.text('약 드실 시간이에요'), findsOneWidget);
    expect(find.byIcon(Icons.notifications_none_outlined), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('실내 센서 값이 없으면 온습도 줄을 지어내지 않는다', (tester) async {
    await _pump(tester);
    expect(find.textContaining('실내'), findsNothing);
  });

  testWidgets('허브에 못 닿으면 인사말만 — 서버와 같은 시간대 규칙', (tester) async {
    await _pump(tester, now: DateTime(2026, 9, 13, 19, 0));
    expect(find.text('편안한 저녁 보내세요'), findsOneWidget);
    expect(KioskIdleView.localGreeting(DateTime(2026, 1, 1, 7)), '좋은 아침이에요.');
    expect(KioskIdleView.localGreeting(DateTime(2026, 1, 1, 13)), '좋은 오후예요.');
    expect(KioskIdleView.localGreeting(DateTime(2026, 1, 1, 23)), '편안한 밤 보내세요.');
  });
  testWidgets('설정은 메뉴 창에서 한 번 누르면 열린다 — 읽는 이름은 "설정"', (tester) async {
    // 위쪽 아이콘을 상태 칩 + 메뉴로 정리했다(화면 구조 개편 10/18). 메뉴는 가운데 큰 창이고 설정은 그 안의 큰 줄이다.
    final semantics = tester.ensureSemantics();
    var opened = 0;
    await _pump(tester, onSettings: () => opened++);
    expect(find.byKey(const ValueKey('settings-entry')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('idle-menu')));
    await tester.pump();
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    expect(find.bySemanticsLabel('설정'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-entry')));
    expect(opened, 1);
    semantics.dispose();
  });

  testWidgets('서버 목록을 못 봤으면 가전을 세우지 않는다', (tester) async {
    await _pump(tester, appliances: null);
    expect(find.text('전자레인지'), findsNothing);
    expect(find.text('본체와 연결되면 가전이 보여요'), findsOneWidget);
  });

  testWidgets('쉬기가 꺼져 있으면 위쪽에 쉬기 글자가 없다 — 메뉴의 잠시 쉬기(48 이상)를 누르면 선택이 열린다',
      (tester) async {
    // 늘 보이던 "방해 금지" 글자 단추는 켜진 것으로 읽혔다(10/5).
    final semantics = tester.ensureSemantics();
    var opened = 0;
    await _pump(tester, onDnd: () => opened++);
    expect(find.text('방해 금지'), findsNothing);
    expect(find.text('쉬는 중'), findsNothing);
    expect(find.byKey(const ValueKey('dnd-chip')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('idle-menu')));
    await tester.pump();
    expect(find.byIcon(Icons.pause_circle_outline), findsOneWidget);
    final size = tester.getSize(find.byKey(const ValueKey('dnd-entry')));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
    await tester.tap(find.byKey(const ValueKey('dnd-entry')));
    expect(opened, 1);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('쉬는 중이면 위 줄 칩에 아이콘·글자·남은 시간 — 누르면 선택이 열린다',
      (tester) async {
    final semantics = tester.ensureSemantics();
    var opened = 0;
    await _pump(tester,
        dndUntil: DateTime(2026, 9, 13, 10, 5), onDnd: () => opened++);
    // 색만으로 말하지 않는다 — 채운 칩 + 아이콘 + 글자.
    // 2026-10-15: '방해 금지' → '쉬는 중'(이름만 보면 제안만 쉬는 줄 알았다) · 남은 시간에 '남음'.
    expect(find.text('쉬는 중'), findsOneWidget);
    expect(find.text('1시간 남음'), findsOneWidget);
    expect(find.byIcon(Icons.pause_circle), findsOneWidget);
    expect(find.bySemanticsLabel('잠시 쉬는 중, 1시간 남음. 끝내려면 누르세요'), findsOneWidget);
    // 위 줄 안, 시계 열이 아니다.
    final chip = tester.getRect(find.byKey(const ValueKey('dnd-chip')));
    expect(chip.bottom, lessThanOrEqualTo(10 + 80 + 0.5));
    expect(chip.height, greaterThanOrEqualTo(48));
    await tester.tap(find.byKey(const ValueKey('dnd-chip')));
    expect(opened, 1);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('끝난 방해 금지 시각은 켜진 것으로 보이지 않는다', (tester) async {
    await _pump(tester, dndUntil: DateTime(2026, 9, 13, 9, 0));
    expect(find.text('쉬는 중'), findsNothing);
    expect(find.byKey(const ValueKey('dnd-chip')), findsNothing);
  });

  testWidgets('이 키오스크는 말을 듣지 않는다 — 할 수 없는 일을 권하지 않는다', (tester) async {
    await _pump(tester,
        ambient: const AmbientInfo(greeting: '좋은 아침이에요.'));
    expect(find.textContaining('말하'), findsNothing);
  });
}
