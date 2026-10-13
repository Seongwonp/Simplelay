// 2026-10-14 문구 정리(외부 UX 평가 56점 — "AI가 만든 것 같다"는 지적의 대부분이 문구였다).
// 시스템 말·되풀이·괄호 단서를 걷어 내되, 연습(모의)이라는 사실은 남긴다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/command_result.dart';
import 'package:simplelay_touchscreen/models/scenario_run.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/connection_status.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';

Future<void> _pump(WidgetTester tester, Widget view) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: view)));
}

Widget _executing(String mode) => KioskExecutingView(
      executionMode: mode,
      title: '즉석밥 데워줘',
      lastButtons: null,
      currentButton: '즉석밥',
      currentAttempt: 1,
      completedSteps: 0,
      verificationConfidence: null,
      verificationDetail: null,
      onStop: () {},
    );

Widget _hold(String mode) => KioskHoldView(
      appliance: kMicrowaveAppliance,
      holdState: 'hovering_stop',
      stopButton: '취소',
      executionMode: mode,
      elapsed: const Duration(minutes: 1),
      onStop: () {},
    );

Finder _inButton<T>(String text) => find.ancestor(
      of: find.text(text),
      matching: find.byWidgetPredicate((w) => w is T),
    );

void main() {
  group('실행 환경 표시 — 연습일 때만 "연습 모드", 실제·모름은 아무것도', () {
    for (final mode in ['real', 'unknown', 'mock']) {
      testWidgets('완료 화면 · $mode', (tester) async {
        await _pump(
          tester,
          KioskDoneView(
            success: true,
            label: '즉석밥 데워줘',
            executionMode: mode,
            onDismiss: () {},
          ),
        );
        expect(find.text('실제 장치로 실행'), findsNothing);
        expect(find.textContaining('실행 환경'), findsNothing);
        expect(find.text('연습 모드'), mode == 'mock' ? findsOneWidget : findsNothing);
      });

      testWidgets('실행 화면 · $mode', (tester) async {
        await _pump(tester, _executing(mode));
        expect(find.text('실제 장치로 실행'), findsNothing);
        expect(find.textContaining('실행 환경'), findsNothing);
        expect(find.text('연습 모드'), mode == 'mock' ? findsOneWidget : findsNothing);
      });

      testWidgets('동작 중 화면 · $mode', (tester) async {
        await _pump(tester, _hold(mode));
        expect(find.textContaining('실행 환경'), findsNothing);
        expect(find.text('연습 모드'), mode == 'mock' ? findsOneWidget : findsNothing);
      });
    }
  });

  group('정지·모터 걸림 뒤에는 "확인 못 함" 칩을 덧붙이지 않는다', () {
    testWidgets('사용자 정지', (tester) async {
      await _pump(
        tester,
        KioskDoneView(
          success: false,
          label: '즉석밥 데워줘',
          reason: KioskFailureReason.stopped,
          confirmation: '눌렸는지 확인 못 했어요',
          onRetry: () {},
          onDismiss: () {},
        ),
      );
      expect(find.textContaining('확인 못 했어요'), findsNothing);
    });

    testWidgets('모터 걸림 안전 정지', (tester) async {
      await _pump(
        tester,
        KioskDoneView(
          success: false,
          label: '즉석밥 데워줘',
          reason: KioskFailureReason.safetyStop,
          abortReason: 'motion_alarm: stall',
          confirmation: '눌렸는지 확인 못 했어요',
          onDismiss: () {},
        ),
      );
      expect(find.text('모터가 걸려 멈췄어요'), findsOneWidget);
      expect(find.textContaining('확인 못 했어요'), findsNothing);
      expect(find.text('다시 시도'), findsNothing);
    });

    test('보내지 않은 물리 단계는 "누르지 않음"', () {
      expect(
        confirmationLabel(
            route: 'physical',
            receipt: 'not_dispatched',
            confirmation: 'none',
            executionMode: 'real'),
        '누르지 않음',
      );
      final facts = runStepFacts(const ScenarioRunStep(
        targetId: 'microwave',
        route: 'physical',
        summary: '전자레인지 즉석밥',
        status: 'stopped',
        receipt: 'not_dispatched',
        confirmation: 'none',
        executionMode: 'real',
      ));
      expect(facts, contains('누르지 않음'));
      expect(facts, isNot(contains('확인 못')));
      expect(facts, isNot(contains('physical')));
      expect(facts, isNot(contains('물리 버튼')));
    });
  });

  testWidgets('사용자 정지는 차분하게 — 손 아이콘, 닫기가 먼저, 같은 말 되풀이 없음', (tester) async {
    await _pump(
      tester,
      KioskDoneView(
        success: false,
        label: '즉석밥 데워줘',
        reason: KioskFailureReason.stopped,
        onRetry: () {},
        onManual: () {},
        onDismiss: () {},
      ),
    );
    expect(find.byIcon(Icons.close), findsNothing);
    expect(find.byIcon(Icons.pan_tool_outlined), findsOneWidget);
    expect(find.text('실행을 멈췄어요'), findsOneWidget);
    expect(find.textContaining('— 실행을 멈췄어요'), findsNothing);
    expect(find.text('기계가 멈췄는지 한 번 봐 주세요.'), findsOneWidget);
    expect(_inButton<ElevatedButton>('닫기'), findsOneWidget);
    expect(_inButton<OutlinedButton>('다시 시도'), findsOneWidget);
    expect(_inButton<ElevatedButton>('다시 시도'), findsNothing);
  });

  group('사용자 정지 — 정지 단계 줄과 같은 당부를 겹쳐 쓰지 않는다', () {
    for (final (level, bodyShown) in [
      ('sent', false),
      ('mcu_ack', true),
      ('verified', false),
      (null, true),
    ]) {
      testWidgets('단계 ${level ?? '없음'}', (tester) async {
        await _pump(
          tester,
          KioskDoneView(
            success: false,
            label: '즉석밥 데워줘',
            reason: KioskFailureReason.stopped,
            stopLevel: level,
            stopAckMs: 9,
            onDismiss: () {},
          ),
        );
        expect(find.text('기계가 멈췄는지 한 번 봐 주세요.'),
            bodyShown ? findsOneWidget : findsNothing);
        expect(find.textContaining('ms'), findsNothing);
        if (level != null) {
          expect(find.text(stopLevelSentence(level)!), findsOneWidget);
        }
      });
    }
  });

  testWidgets('이름을 모르면 "실행 — " 머리를 붙이지 않는다', (tester) async {
    await _pump(
      tester,
      KioskDoneView(
        success: false,
        label: '',
        reason: KioskFailureReason.safetyStop,
        onDismiss: () {},
      ),
    );
    expect(find.textContaining(' — '), findsNothing);
    expect(find.text('눌림을 확인하지 못해 안전하게 멈췄어요.\n가전을 살펴본 뒤 다시 시도해 주세요.'),
        findsOneWidget);
  });

  group('평소 화면 위 줄', () {
    Future<void> pumpIdle(WidgetTester tester, List<ConnectionItem> conns) async {
      tester.view.physicalSize = const Size(800, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: KioskIdleView(
            now: DateTime(2026, 9, 13, 9, 5),
            connected: true,
            appliances: const [kMicrowaveAppliance],
            connections: conns,
            onSelectAppliance: (_) {},
            onOpenConnection: (_) {},
            onDndGesture: () {},
            onSettingsGesture: () {},
          ),
        ),
      ));
    }

    testWidgets('설정은 조용한 아이콘 단추 — 글자 알약이 아니고, 48 이상·이름은 "설정"', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpIdle(tester, const []);
      final entry = find.byKey(const ValueKey('settings-entry'));
      expect(tester.widget(entry), isA<IconButton>());
      expect(find.text('설정'), findsNothing);
      expect(find.bySemanticsLabel('설정'), findsOneWidget);
      final size = tester.getSize(entry);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      semantics.dispose();
    });

    testWidgets('플러그(콘센트 모듈)가 설치되지 않았으면 아이콘을 그리지 않는다', (tester) async {
      await pumpIdle(tester, const [
        ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
        ConnectionItem(id: 'plug', state: 'not_installed', title: '', message: ''),
      ]);
      expect(find.byKey(const ValueKey('conn-network')), findsOneWidget);
      expect(find.byKey(const ValueKey('conn-plug')), findsNothing);
      expect(find.byType(KioskConnectionIcons), findsOneWidget);
    });
  });
}
