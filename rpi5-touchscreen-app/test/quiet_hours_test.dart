// 조용한 시간(2026-10-14, 5번) — 키오스크가 폰과 같은 서버 상태(/health의 quiet)를 보이고, 실제 범위만 말한다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/dnd_overlay.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';

const _quietJson = {
  'ok': true,
  'actuator_ready': true,
  'dnd_until': null,
  'quiet': {
    'enabled': true,
    'start': '22:00',
    'end': '07:00',
    'active': true,
    'reason': 'schedule',
    'pause_until': null,
    'scope': '새 제안과 일반 안내 소리만 쉬어요. 아직 시작하지 않은 자동 실행은 건너뛰고 나중에 다시 하지 않아요.',
  },
};

void main() {
  test('/health의 quiet를 읽는다(옛 서버는 꺼짐)', () {
    final h = HealthStatus.fromJson(_quietJson);
    expect(h.quietActive, isTrue);
    expect(h.quietSchedule, ('22:00', '07:00'));
    expect(h.quietScheduleActive, isTrue);
    final old = HealthStatus.fromJson(const {'ok': true});
    expect(old.quietActive, isFalse);
    expect(old.quietSchedule, isNull);
  });

  testWidgets('평소 화면: 매일 조용한 시간이면 위 줄 칩이 "조용한 시간 · 07:00까지"', (tester) async {
    final handle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(800, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: KioskIdleView(
          now: DateTime(2026, 10, 14, 23, 5),
          connected: true,
          appliances: const [kMicrowaveAppliance],
          quietUntil: '07:00',
          onSelectAppliance: (_) {},
          onOpenConnection: (_) {},
          onDndGesture: () {},
        ),
      ),
    ));
    expect(find.text('조용한 시간'), findsOneWidget);
    expect(find.text('07:00까지'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^조용한 시간, 07:00까지')), findsOneWidget);
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  testWidgets('방해 금지 창: 실제 범위만 말하고, 매일 시간대를 보인다(바꾸기는 폰)', (tester) async {
    tester.view.physicalSize = const Size(800, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DndOverlay(
          dndUntil: null,
          quietSchedule: ('22:00', '07:00'),
          onSet: (_) {},
          onClear: () {},
          onDismiss: () {},
        ),
      ),
    ));
    expect(find.text('새 제안과 자동 실행을 잠시 쉬어요'), findsOneWidget);
    expect(find.text('매일 22:00~07:00 조용한 시간 · 바꾸기는 폰 설정에서'), findsOneWidget);
    expect(find.textContaining('모든'), findsNothing);
    expect(find.textContaining('사용 습관 제안'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // 2026-10-14 4·5번 마감 확인 A5: 잠시 쉬기가 켜져 있으면 '언제까지'(끝나는 시각)를 함께 적는다.
  testWidgets('방해 금지 창: 켜져 있으면 끝나는 시각까지 쉰다고 적는다', (tester) async {
    tester.view.physicalSize = const Size(800, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DndOverlay(
          dndUntil: DateTime(2026, 10, 14, 23, 30),
          onSet: (_) {},
          onClear: () {},
          onDismiss: () {},
        ),
      ),
    ));
    expect(find.text('23:30까지 새 제안과 자동 실행을 쉬고 있어요'), findsOneWidget);
    expect(find.text('방해 금지 해제'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
