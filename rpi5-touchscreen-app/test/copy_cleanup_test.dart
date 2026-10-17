// 2026-10-14 문구 정리(외부 UX 평가 56점 — "AI가 만든 것 같다"는 지적의 대부분이 문구였다).
// 시스템 말·되풀이·괄호 단서를 걷어 내되, 연습(모의)이라는 사실은 남긴다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/idle_menu.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/command_result.dart';
import 'package:simplelay_touchscreen/models/scenario_run.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/practice_band.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

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
  // 2026-10-15: 완료·동작 중 화면은 작은 칩 대신 맨 위 띠("연습 중이에요. 실제 가전에는 보내지 않아요").
  group('실행 환경 표시 — 연습일 때만 연습 표시, 실제·모름은 아무것도', () {
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
        expect(find.text(kPracticeBandText), mode == 'mock' ? findsOneWidget : findsNothing);
        expect(find.text('연습 모드'), findsNothing);
      });

      testWidgets('실행 화면 · $mode', (tester) async {
        await _pump(tester, _executing(mode));
        expect(find.text('실제 장치로 실행'), findsNothing);
        expect(find.textContaining('실행 환경'), findsNothing);
        expect(find.text(kPracticeBandText), mode == 'mock' ? findsOneWidget : findsNothing);
        expect(find.text('연습 모드'), findsNothing);
      });

      testWidgets('동작 중 화면 · $mode', (tester) async {
        await _pump(tester, _hold(mode));
        expect(find.textContaining('실행 환경'), findsNothing);
        expect(find.text(kPracticeBandText), mode == 'mock' ? findsOneWidget : findsNothing);
        expect(find.text('연습 모드'), findsNothing);
      });
    }
  });

  group('정지·모터 걸림 뒤에는 "몰라요" 칩을 덧붙이지 않는다', () {
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
      expect(find.text('작은 팔이 걸려 멈췄어요'), findsOneWidget);
      expect(find.textContaining('확인 못 했어요'), findsNothing);
      expect(find.text('한 번 더 하기'), findsNothing);
    });

    test('보내지 않은 물리 단계는 "누르지 않음"', () {
      expect(
        confirmationLabel(
            route: 'physical',
            receipt: 'not_dispatched',
            confirmation: 'none',
            executionMode: 'real'),
        '누르지 않았어요',
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
      expect(facts, contains('누르지 않았어요'));
      expect(facts, isNot(contains('확인 못')));
      expect(facts, isNot(contains('physical')));
      expect(facts, isNot(contains('물리 버튼')));
    });
  });

  // 2026-10-15: 정지 단계를 모르면 멈췄는지 모른다 — 물음표·주의색. '처음 화면으로'가 먼저, '다시 시도'는 테두리.
  testWidgets('사용자 정지 — 빨간 X 없이, 처음 화면으로가 먼저, 같은 말 되풀이 없음', (tester) async {
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
    expect(find.byIcon(Icons.question_mark), findsOneWidget);
    // 단계를 모르면 확인하지 못한 정지다 — 결과 화면은 멈췄어요/멈췄는지 몰라요 둘뿐(평가 8차 10/18).
    expect(find.text('작은 팔이 멈췄는지 몰라요'), findsOneWidget);
    expect(find.textContaining('— 정지 요청으로'), findsNothing);
    expect(find.text('가전을 봐 주세요'), findsOneWidget);
    expect(_inButton<ElevatedButton>('처음 화면으로'), findsOneWidget);
    // 직접 멈춘 결과에는 '다시 시도'가 없다(UI 평가 5차 10/17 — 다시 누를 위험).
    expect(find.text('한 번 더 하기'), findsNothing);
  });

  group('사용자 정지 — 제목은 정지 단계, 할 일은 한 줄만', () {
    for (final level in ['sent', 'mcu_ack', 'verified', null]) {
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
        expect(find.text(stopLevelHeadline(level)), findsOneWidget);
        expect(find.text(stopLevelNextStep(level)), findsOneWidget);
        // 예전 말('기계')·응답 시간은 쓰지 않는다.
        expect(find.textContaining('기계'), findsNothing);
        expect(find.textContaining('ms'), findsNothing);
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
    // 다시 시도 단추가 없으면 그 단추 이야기(이미 켜졌다면 다시 시도하지 마세요)도 하지 않는다.
    expect(find.text('가전을 봐 주세요'), findsOneWidget);
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

    testWidgets('위쪽은 조용한 메뉴 단추 — 글자 알약이 아니고, 48 이상·설정은 메뉴 창 안의 큰 줄', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpIdle(tester, const []);
      final menu = find.byKey(const ValueKey('idle-menu'));
      // 금색 알약이 아니라 회색 아이콘 + 아래 이름(화면 구조 개편 10/18 — 쉬기·설정은 메뉴로).
      expect(find.descendant(of: menu, matching: find.byType(Material)), findsNothing);
      final label = tester.widget<Text>(find.descendant(of: menu, matching: find.text('메뉴')));
      expect(label.style?.color, KioskColors.muted);
      final size = tester.getSize(menu);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      await tester.tap(menu);
      await tester.pump();
      expect(find.bySemanticsLabel('설정'), findsOneWidget);
      expect(tester.getSize(find.byKey(const ValueKey('settings-entry'))).height, greaterThanOrEqualTo(48));
      semantics.dispose();
    });

    testWidgets('플러그(콘센트 모듈)가 설치되지 않았으면 연결 목록에 그리지 않는다', (tester) async {
      await pumpIdle(tester, const [
        ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
        ConnectionItem(id: 'plug', state: 'not_installed', title: '', message: ''),
      ]);
      // 설치 안 한 콘센트는 문제가 아니다 — 칩은 '모두 정상'.
      expect(find.text('모두 정상'), findsOneWidget);
      await openIdleConnections(tester);
      expect(find.byKey(const ValueKey('conn-network')), findsOneWidget);
      expect(find.byKey(const ValueKey('conn-plug')), findsNothing);
    });
  });

  group('승인 카드(10/14 재평가)', () {
    Future<void> pumpCard(WidgetTester tester, KioskSuggestion s) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: KioskSuggestionView(
            suggestion: s,
            target: kMicrowaveAppliance,
            cdRemaining: 20,
            cdTotal: 20,
            onApprove: () {},
            onReject: () {},
          ),
        ),
      ));
      await tester.pump();
    }

    const routineRun = KioskSuggestion(
      id: 's1',
      purpose: "'아침 데우기' 루틴을 실행할까요?",
      occurrences: 0,
      routineId: 'rt-1',
      reason: "루틴 '아침 데우기' · 직접 실행을 눌렀어요",
      commands: [
        KioskSuggestionCommand(
            targetId: 'home_mw', route: 'physical', buttons: ['즉석밥', '시작'], summary: '전자레인지 즉석밥 → 시작'),
      ],
    );

    testWidgets('버튼 누름 단계에 "경로 모름" 경고 칩을 붙이지 않는다', (tester) async {
      await pumpCard(tester, routineRun);
      expect(find.text('경로 모름'), findsNothing);
    });

    testWidgets('내가 직접 시작한 루틴은 근거 줄이 없고 목록 제목은 "누를 버튼"', (tester) async {
      await pumpCard(tester, routineRun);
      expect(find.textContaining('직접 실행을 눌렀어요'), findsNothing);
      expect(find.textContaining('근거:'), findsNothing);
      expect(find.text('승인하면 할 일'), findsNothing);
      expect(find.text('누를 버튼'), findsOneWidget);
    });

    testWidgets('자동 제안(사용자가 시작하지 않음)은 근거 줄을 그대로 보인다', (tester) async {
      await pumpCard(tester, const KioskSuggestion(
        id: 's3', purpose: '공기청정기 바람 세기를 강으로 바꿀까요?', occurrences: 0,
        scenarioId: 'cook_done_air',
        reason: '전자레인지 가열 종료를 콘센트 전력(CT)으로 감지했어요',
        commands: [KioskSuggestionCommand(targetId: 'air_purifier', route: 'thinq', summary: '공기청정기 풍량 강')],
      ));
      expect(find.textContaining('가열 종료를 콘센트 전력'), findsOneWidget);
      expect(find.text('할 일'), findsOneWidget);
    });

    testWidgets('정말 모르는 경로는 여전히 확인 필요라고 말한다', (tester) async {
      await pumpCard(tester, const KioskSuggestion(
        id: 's2', purpose: '무언가', occurrences: 0,
        commands: [KioskSuggestionCommand(targetId: 'x', route: 'mystery', summary: '알 수 없는 동작')],
      ));
      expect(find.text('경로 모름'), findsOneWidget);
    });
  });
}
