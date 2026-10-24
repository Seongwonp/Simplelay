// 10/24 코드 검토 수리 — 연속 조작(R7) 뒤 결과·조작판 화면에서도 정지 대기 화면으로 가는지, 사람 확인 답이 두 번 적히지
// 않는지, 조작판 루틴 카드 기억이 남지 않는지, 막힌 대표 동작의 '해결 방법 보기'가 막힌 가전을 여는지, 앱 테마(대화 창)가
// 지금 색 한 벌을 따르는지, 정지 단추 테두리가 밝은 바탕에서도 보이는지, 루틴 trigger 모양이 달라도 읽기가 깨지지 않는지.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/main.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/run_frame.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

const _succeeded = KioskStatus(
    running: false,
    lastJobId: 'job-1',
    lastStatus: 'succeeded',
    lastExecutionMode: 'real',
    lastOperationConfirmed: true,
    lastOperationSource: 'real');

/// 누름 보고만(사람이 가전을 보고 답하는 결과).
const _reported = KioskStatus(
    running: false,
    lastJobId: 'job-1',
    lastApplianceId: 'microwave',
    lastOutcome: 'success',
    lastStatus: 'succeeded',
    lastExecutionMode: 'real',
    lastConfirmation: 'reported');

/// 같은 실행 뒤 가전이 돌아가는 중 — 정지 버튼 대기(실제).
const _hovering = KioskStatus(
    running: false,
    holdState: 'hovering_stop',
    holdApplianceId: 'microwave',
    holdStopButton: '취소',
    holdExecutionMode: 'real',
    lastJobId: 'job-1',
    lastOutcome: 'success',
    lastStatus: 'succeeded',
    lastApplianceId: 'microwave',
    lastExecutionMode: 'real',
    lastOperationConfirmed: true,
    lastOperationSource: 'real');

const _morning = KioskRoutine(id: 'morning', name: '아침 데우기', applianceIds: ['microwave'], pressCount: 2);
const _card = KioskSuggestion(
  id: 'card-1',
  purpose: '아침 데우기',
  occurrences: 0,
  applianceId: 'microwave',
  steps: ['30초', '시작'],
  routineId: 'morning',
  routineName: '아침 데우기',
);

Future<FakeKioskApi> _pumpKiosk(WidgetTester tester, {FakeKioskApi? api}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  api ??= FakeKioskApi()..applianceList = [kMicrowaveAppliance];
  await tester.pumpWidget(MaterialApp(home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream())));
  await tester.pump();
  await tester.pump();
  return api;
}

/// 처음 화면 → 전자레인지 → '해동' → 누르기 → [result] 결과.
Future<void> _pressAndFinish(WidgetTester tester, FakeKioskApi api, {KioskStatus result = _succeeded}) async {
  await tester.tap(find.byKey(const ValueKey('strip-microwave')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text('해동'));
  await tester.pump();
  await tester.tap(find.text('누르기'));
  await tester.pump();
  api.statusResult = result;
  await tester.pump(const Duration(seconds: 2));
  await tester.pump(const Duration(milliseconds: 900));
  expect(find.byType(KioskDoneView), findsOneWidget);
}

Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  const step = Duration(seconds: 1);
  for (var t = Duration.zero; t < total; t += step) {
    await tester.pump(step);
  }
}

final _continue = find.byKey(const ValueKey('done-continue'));

void main() {
  tearDown(() {
    KioskColors.setDarkMode(false);
    KioskColors.setHighContrast(false);
    KioskColors.setQuietNight(false);
  });

  group('1. 연속 조작 중에도 정지 대기 화면', () {
    testWidgets('결과 화면(계속 조작)에 머물러도 대기가 생기면 결과를 읽을 시간 뒤 정지 대기 화면으로', (tester) async {
      final api = await _pumpKiosk(tester);
      await _pressAndFinish(tester, api);
      expect(_continue, findsOneWidget);
      api.statusResult = _hovering;
      // 결과를 읽을 시간(종전 자동 복귀 길이) 안에는 결과 그대로.
      await _pumpFor(tester, const Duration(seconds: 4));
      expect(find.byType(KioskDoneView), findsOneWidget);
      await _pumpFor(tester, const Duration(seconds: 30));
      expect(find.byType(KioskHoldView), findsOneWidget);
      expect(find.byType(KioskDoneView), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('계속 조작으로 들어간 조작판에서도 대기가 생기면 정지 대기 화면으로', (tester) async {
      final api = await _pumpKiosk(tester);
      await _pressAndFinish(tester, api);
      await tester.tap(_continue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(KioskManualView), findsOneWidget);
      api.statusResult = _hovering;
      await _pumpFor(tester, const Duration(seconds: 5));
      expect(find.byType(KioskHoldView), findsOneWidget);
      expect(find.byType(KioskManualView), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('2. 본체에 닿지 않을 때 사람 확인에 답하면 한 번만 적고 처음 화면으로', (tester) async {
    final api = await _pumpKiosk(tester);
    await _pressAndFinish(tester, api, result: _reported);
    expect(find.byKey(const ValueKey('done-check-yes')), findsOneWidget);
    api.healthResult = const HealthStatus(ok: false);
    await _pumpFor(tester, const Duration(seconds: 11));
    expect(find.byType(KioskDoneView), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('done-check-yes')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(KioskDoneView), findsNothing);
    expect(find.byType(KioskIdleView), findsOneWidget);
    expect(api.ackPosts, [('job-1', 'moved')]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('3. 조작판 루틴 카드 기억은 카드가 끝나면 지운다 — 같은 카드가 스스로 다시 떠도 계속 조작을 붙이지 않는다',
      (tester) async {
    final api = FakeKioskApi()
      ..applianceList = [kMicrowaveAppliance]
      ..routinesResult = const [_morning]
      ..triggerResult = const RoutineTriggerResult(suggestion: _card);
    await _pumpKiosk(tester, api: api);
    await tester.tap(find.byKey(const ValueKey('strip-microwave')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('routine-morning')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(KioskSuggestionView), findsOneWidget);
    // 다른 단말이 카드를 내렸다 — 처음 화면으로.
    await _pumpFor(tester, const Duration(seconds: 6));
    expect(find.byType(KioskIdleView), findsOneWidget);
    // 같은 카드가 나중에 스스로 뜬 제안으로 다시 온다.
    api.suggestionList = [_card];
    await _pumpFor(tester, const Duration(seconds: 3));
    expect(find.byType(KioskSuggestionView), findsOneWidget);
    api.suggestionList = [];
    await tester.tap(find.byKey(const ValueKey('suggestion-approve')));
    await tester.pump();
    api.statusResult = _succeeded;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.byType(KioskDoneView), findsOneWidget);
    expect(_continue, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets("4. 막힌 대표 동작의 '해결 방법 보기'는 막힌 가전의 안내를 연다(루틴 첫 가전이 아니라)", (tester) async {
    const air = ApplianceMap(
        id: 'air', name: '공기청정기', category: 'air_purifier', rows: 0, cols: 0, buttons: [],
        controlPath: 'thinq', readiness: 'operable');
    const both = KioskRoutine(id: 'both', name: '둘 다', applianceIds: ['air', 'microwave'], pressCount: 2, settingCount: 1);
    final selected = <String>[];
    final opened = <String>[];
    tester.view.physicalSize = const Size(800, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: KioskIdleView(
          now: DateTime(2026, 10, 24, 15, 12),
          connected: true,
          appliances: const [air, kMicrowaveAppliance],
          connections: const [ConnectionItem(id: 'press', state: 'error', title: '누름 장치', message: '연결되지 않았어요')],
          onSelectAppliance: (a) => selected.add(a.id),
          onOpenConnection: (c) => opened.add(c.id),
          onDndGesture: () {},
          routines: const [both],
          onRoutine: (_) {},
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    // 위 연결 문제 띠가 '해결 방법 보기'를 보이므로 카드는 되풀이하지 않는다(첫 사용 평가 4차 10/24) — 카드를 누르면 같은 안내.
    expect(find.descendant(of: find.byKey(const ValueKey('idle-featured')), matching: find.text('해결 방법 보기')),
        findsNothing);
    await tester.tap(find.byKey(const ValueKey('idle-featured-run')));
    await tester.pump();
    expect(selected, isEmpty, reason: '쓸 수 있는 공기청정기 조작판을 열지 않는다');
    expect(opened, ['press']);
  });

  testWidgets('5. 앱 테마(대화 창이 쓰는 색)는 어두운 화면·고대비를 따른다', (tester) async {
    await tester.pumpWidget(const KioskThemedApp(home: SizedBox.shrink()));
    ThemeData appTheme() => tester.widget<MaterialApp>(find.byType(MaterialApp)).theme!;
    expect(appTheme().brightness, Brightness.light);
    KioskColors.setDarkMode(true);
    await tester.pump();
    await tester.pump();
    expect(appTheme().brightness, Brightness.dark);
    expect(appTheme().scaffoldBackgroundColor, KioskColors.dark.bg);
    expect(appTheme().colorScheme.surface, KioskColors.dark.surface);
    KioskColors.setDarkMode(false);
    KioskColors.setHighContrast(true);
    await tester.pump();
    await tester.pump();
    expect(appTheme().scaffoldBackgroundColor, KioskColors.contrast.bg);
    KioskColors.setHighContrast(false);
    await tester.pump();
    await tester.pump();
    expect(appTheme().brightness, Brightness.light);
    expect(appTheme().scaffoldBackgroundColor, KioskColors.light.bg);
  });

  group('6. 정지 단추 테두리', () {
    for (final (name, set) in <(String, void Function())>[
      ('밝은 화면', () {}),
      ('어두운 화면', () => KioskColors.setDarkMode(true)),
      ('고대비', () => KioskColors.setHighContrast(true)),
    ]) {
      testWidgets('$name — 바탕과 3:1 이상(색을 빼도 보이는 모양 단서)', (tester) async {
        set();
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Center(child: KioskStopButton(label: '정지', onPressed: () {}, buttonKey: const ValueKey('s'))),
          ),
        ));
        final button = tester.widget<ElevatedButton>(find.byKey(const ValueKey('s')));
        final shape = button.style!.shape!.resolve(<WidgetState>{}) as RoundedRectangleBorder;
        final side = shape.side.color;
        double lum(Color c) => c.computeLuminance();
        final a = lum(side), b = lum(KioskColors.bg);
        final ratio = (a > b ? a + 0.05 : b + 0.05) / (a > b ? b + 0.05 : a + 0.05);
        expect(ratio, greaterThanOrEqualTo(3.0));
        expect(button.style!.backgroundColor!.resolve(<WidgetState>{}), KioskColors.stop);
        expect(button.style!.foregroundColor!.resolve(<WidgetState>{}), Colors.white);
      });
    }
  });

  group('7. 루틴 읽기', () {
    test('trigger가 맵이 아니어도 깨지지 않는다', () {
      final r = KioskRoutine.fromJson({'id': 'x', 'name': 'x', 'trigger': 'time'});
      expect(r.timeTriggered, isFalse);
      final ok = KioskRoutine.fromJson({
        'id': 'y',
        'trigger': <dynamic, dynamic>{'kind': 'time'},
      });
      expect(ok.timeTriggered, isTrue);
    });
  });
}
