// 2026-10-14 차가운 UX 평가(56/100, "AI가 만든 것 같다") 수리 — 문구·배치만.
//
// 정직성 규칙은 그대로다: 모의는 표시하고, 확인 못 한 것을 성공이나 실패로 말하지 않는다.
// 이 파일은 수리 전 코드에서 실패하는 것을 확인한 뒤 수리했다(red-first).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/models/routine.dart';
import 'package:simplelay/models/scenario_run.dart';
import 'package:simplelay/models/suggestion.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/routines_screen.dart' show routineSubtitle;
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/screens/status_screen.dart';
import 'package:simplelay/screens/suggestion_screen.dart';

import '../helpers/test_helpers.dart';

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 사용자가 루틴 '실행'을 눌러 만든 카드(서버 `trigger_manual`의 근거 문장).
Suggestion _routineCard({required String reason}) => Suggestion(
      sequenceId: 'sug-1',
      label: "'아침 데우기' 루틴을 실행할까요?",
      steps: const [],
      source: SuggestionSource.http,
      reason: reason,
      timeBand: '루틴',
      applianceId: 'microwave',
      routineId: 'rt-1',
      routineName: '아침 데우기',
      commands: const [
        SuggestionCommand(
          targetId: 'microwave',
          route: 'physical',
          buttons: ['즉석밥', '시작'],
          summary: '전자레인지 즉석밥 → 시작',
        ),
      ],
    );

ApplianceMap _named(String id, String name, {String? location}) {
  final t = kTestAppliance;
  return ApplianceMap(
    id: id,
    name: name,
    category: t.category,
    rows: t.rows,
    cols: t.cols,
    buttons: t.buttons,
    location: location,
  );
}

Widget _home({
  required List<ApplianceMap> installed,
  bool bleConnected = true,
  RpiConnectionState server = RpiConnectionState.connected,
}) =>
    buildScreen(
      const HomeScreen(),
      overrides: [
        ...(bleConnected ? connectedOverrides() : disconnectedOverrides()),
        ...installedOverrides(installed),
        rpiServerOverride(server),
      ],
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('2 — 멈춘 실행에 "눌렸는지 몰라요"를 붙이지 않는다', () {
    for (final (outcome, abort) in [
      ('stopped', null),
      ('safety_stop', 'motion_alarm: stall'),
    ]) {
      testWidgets('$outcome${abort == null ? '' : ' · $abort'}', (tester) async {
        _tall(tester);
        await tester.pumpWidget(buildScreen(const StatusScreen(),
            executionStatus: ExecutionStatus(
              phase: ExecutionPhase.failed,
              outcome: outcome,
              abortReason: abort,
              route: 'physical',
              confirmation: 'none',
              executionMode: 'real',
              label: '아침 데우기',
            )));
        await tester.pump();
        expect(find.text('눌렸는지 몰라요'), findsNothing);
      });
    }

    test('누르기 전에 멈춘 단계는 "누르지 않았어요" — "확인하지 못했어요"가 아니다', () {
      const step = ScenarioRunStep(
        targetId: 'microwave',
        route: 'physical',
        status: 'stopped',
        receipt: 'not_dispatched',
        confirmation: 'none',
        executionMode: 'real',
      );
      final facts = runStepFacts(step);
      expect(facts, contains('누르지 않았어요'));
      expect(facts, isNot(contains('확인하지 못했어요')));
    });
  });

  group('3 — 직접 실행한 루틴은 "이대로 할까요?", 제안 전용 문구를 빼고 안심 문장을 줄인다', () {
    testWidgets('직접', (tester) async {
      _tall(tester);
      await tester.pumpWidget(buildScreen(
        const SuggestionScreen(sequenceId: 'sug-1'),
        overrides: connectedOverrides(),
        suggestions: [_routineCard(reason: "루틴 '아침 데우기' · 직접 실행을 눌렀어요")],
      ));
      await tester.pump();

      expect(find.text('이대로 할까요?'), findsOneWidget);
      expect(find.text('할까요?'), findsNothing);
      expect(find.textContaining('이유:'), findsNothing);
      expect(find.text('30분 동안 묻지 않기'), findsNothing);
      expect(find.text('이 일은 다시 묻지 않기'), findsNothing);
      expect(find.text('누를 버튼'), findsOneWidget);
      expect(find.text('승인하면 할 일'), findsNothing);
      expect(find.textContaining('승인하면 위 내용 그대로만'), findsNothing);
      expect(find.textContaining('누르지 않으면 실행하지 않아요'), findsNothing);
      expect(find.text('버튼을 대신 눌러요'), findsNothing);
      expect(find.text('지금 하기'), findsOneWidget);
    });

    testWidgets('시각 루틴이 만든 카드는 제안이다 — 근거·다시 받지 않기를 남긴다', (tester) async {
      _tall(tester);
      await tester.pumpWidget(buildScreen(
        const SuggestionScreen(sequenceId: 'sug-1'),
        overrides: connectedOverrides(),
        suggestions: [_routineCard(reason: "루틴 '아침 데우기' · 평일 07:30 시각이에요")],
      ));
      await tester.pump();

      expect(find.text('할까요?'), findsOneWidget);
      expect(find.textContaining('이유:'), findsOneWidget);
      // 다시 받지 않기는 '더 보기' 안(2026-10-14 UI 정리).
      await tester.tap(find.byKey(const Key('suggestion-more')));
      await tester.pumpAndSettle();
      expect(find.text('이 일은 다시 묻지 않기'), findsOneWidget);
      expect(find.textContaining('승인하면 위 내용 그대로만'), findsNothing);
      expect(find.text('버튼을 대신 눌러요'), findsNothing);
    });
  });

  group('4 — 누름 장치 등록은 개발자 탭으로', () {
    testWidgets('설정에 "버튼을 눌러 줄 장치" 구획이 없다', (tester) async {
      _tall(tester);
      await tester.pumpWidget(buildScreen(const SettingsScreen(),
          overrides: [
            ...connectedOverrides(),
            rpiServerOverride(RpiConnectionState.connected),
          ]));
      await tester.pump();
      expect(find.textContaining('버튼을 눌러 줄 장치'), findsNothing);
      expect(find.text('등록할 가전이 아직 없어요'), findsNothing);
    });
  });

  group('7 — 홈 잡음', () {
    test('직접 실행 루틴의 부제에 "직접 실행할 때"를 넣지 않는다', () {
      const r = Routine(
        id: 'r1',
        name: '아침 데우기',
        steps: [RoutineStep.press('mw', ['즉석밥', '시작'])],
        when: '직접 실행할 때',
      );
      expect(routineSubtitle(r, const {'mw': '전자레인지'}).replaceAll(kWordJoiner, ''),
          '전자레인지 · 누를 버튼 2개');
    });

    testWidgets('허브가 닿으면 예비 연결이 꺼져도 연결 줄을 두지 않는다', (tester) async {
      _tall(tester);
      await tester.pumpWidget(
          _home(installed: [kTestAppliance], bleConnected: false));
      await tester.pump();
      expect(find.text('예비 연결 꺼짐'), findsNothing);
      expect(find.text('확인하기'), findsNothing);
    });

    testWidgets('설정이 남은 가전 여럿은 한 줄 — 이름과 "설정이 남았어요"', (tester) async {
      _tall(tester);
      final a = ApplianceMap(
        id: 'w1', name: '세탁기', category: kTestAppliance.category,
        rows: 1, cols: 1, buttons: const [], isCustom: true);
      final b = ApplianceMap(
        id: 'w2', name: '건조기', category: kTestAppliance.category,
        rows: 1, cols: 1, buttons: const [], isCustom: true);
      await tester.pumpWidget(_home(installed: [a, b]));
      await tester.pump();
      expect(findPlainText('세탁기, 건조기 설정이 남았어요'), findsOneWidget);
      expect(find.text('설정 이어하기'), findsNothing);
      expect(find.textContaining('설정이 남은 가전'), findsNothing);
    });
  });

  group('8 — 같은 이름 가전 구분(표시만)', () {
    testWidgets('방이 없고 이름이 같으면 두 번째부터 "(2)"', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_home(installed: [
        _named('m1', '전자레인지'),
        _named('m2', '전자레인지'),
      ]));
      await tester.pump();
      expect(
          find.descendant(
              of: find.byKey(const Key('appliance-card-m1')),
              matching: find.text('전자레인지')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const Key('appliance-card-m2')),
              matching: find.text('전자레인지 (2)')),
          findsOneWidget);
    });

    testWidgets('방이 다르면 이름은 그대로, 방을 부제로', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_home(installed: [
        _named('m1', '전자레인지', location: '주방'),
        _named('m2', '전자레인지', location: '거실'),
      ]));
      await tester.pump();
      expect(find.text('전자레인지 (2)'), findsNothing);
      expect(find.text('거실'), findsOneWidget);
    });
  });
}
