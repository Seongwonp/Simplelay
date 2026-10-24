// 키오스크 연속 조작(2026-10-24, UI 재설계 계획 R7) — 직접 고른 가전에서 실행한 결과는 처음 화면으로 튕기지 않고
// '이 가전 계속 조작'으로 같은 조작판에 돌아간다. 계속 조작은 탐색일 뿐 명령을 다시 보내지 않는다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_select_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

const _succeeded = KioskStatus(
    running: false,
    lastJobId: 'job-1',
    lastStatus: 'succeeded',
    lastExecutionMode: 'real',
    lastOperationConfirmed: true,
    lastOperationSource: 'real');

Future<FakeKioskApi> _pumpKiosk(WidgetTester tester, {List<KioskSuggestion> suggestions = const []}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final api = FakeKioskApi()
    ..applianceList = [kMicrowaveAppliance]
    ..suggestionList = [...suggestions];
  await tester.pumpWidget(MaterialApp(home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream())));
  await tester.pump();
  await tester.pump();
  return api;
}

/// 처음 화면 → 전자레인지 → '해동' → 누르기 → 성공 결과.
Future<void> _pressAndSucceed(WidgetTester tester, FakeKioskApi api) async {
  await tester.tap(find.byKey(const ValueKey('strip-microwave')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text('해동'));
  await tester.pump();
  await tester.tap(find.text('누르기'));
  await tester.pump();
  api.statusResult = _succeeded;
  await tester.pump(const Duration(seconds: 2));
  await tester.pump(const Duration(milliseconds: 900));
  expect(find.byType(KioskDoneView), findsOneWidget);
}

final _continue = find.byKey(const ValueKey('done-continue'));

void main() {
  testWidgets('직접 누른 성공은 처음 화면으로 저절로 가지 않고, 계속 조작은 다시 보내지 않고 같은 조작판으로', (tester) async {
    final api = await _pumpKiosk(tester);
    await _pressAndSucceed(tester, api);
    expect(api.executeCalls, 1);
    expect(_continue, findsOneWidget);
    expect(find.text('전자레인지 계속 조작'), findsOneWidget);
    expect(find.byKey(const ValueKey('done-auto-return')), findsNothing);

    // 예전 자동 복귀(10초·큰 글씨 20초)를 넘겨도 결과에 머문다.
    await tester.pump(const Duration(seconds: 30));
    expect(find.byType(KioskDoneView), findsOneWidget);

    await tester.tap(_continue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final manual = tester.widget<KioskManualView>(find.byType(KioskManualView));
    expect(manual.appliance.id, 'microwave');
    expect(api.executeCalls, 1, reason: '계속 조작은 탐색 — 명령을 다시 보내지 않는다');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets("'다른 가전 고르기'는 가전 고르기로 — 명령은 다시 보내지 않는다", (tester) async {
    final api = await _pumpKiosk(tester);
    await _pressAndSucceed(tester, api);
    await tester.tap(find.byKey(const ValueKey('done-pick-other')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(KioskApplianceSelectView), findsOneWidget);
    expect(api.executeCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('그사이 폰에서 지운 가전이면 계속 조작은 가전 고르기로 — 다른 가전으로 메우지 않는다', (tester) async {
    final api = await _pumpKiosk(tester);
    await _pressAndSucceed(tester, api);
    api.applianceList = [
      const ApplianceMap(id: 'rice', name: '밥솥', category: 'rice_cooker', rows: 1, cols: 1, buttons: []),
    ];
    // 가전 목록을 새로 받게 한다(30초 주기보다 길게).
    await tester.pump(const Duration(seconds: 61));
    await tester.tap(_continue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(KioskManualView), findsNothing);
    expect(find.byType(KioskApplianceSelectView), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('스스로 뜬 제안을 승인한 성공은 종전처럼 처음 화면으로 돌아가고 계속 조작이 없다', (tester) async {
    final api = await _pumpKiosk(tester, suggestions: const [
      KioskSuggestion(id: 's1', purpose: '즉석밥 데워줘', occurrences: 3, applianceId: 'microwave'),
    ]);
    await tester.pump(const Duration(seconds: 1));
    api.suggestionList = [];
    await tester.tap(find.byKey(const ValueKey('suggestion-approve')));
    await tester.pump();
    api.statusResult = _succeeded;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.byType(KioskDoneView), findsOneWidget);
    expect(_continue, findsNothing);
    expect(find.byKey(const ValueKey('done-auto-return')), findsOneWidget);
    await tester.pump(const Duration(seconds: 12));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(KioskIdleView), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('연습 결과를 닫으면 같은 실행의 연습 대기 화면을 다시 띄우지 않는다(실행은 그대로 보임)', (tester) async {
    // 10/24 모의 보드 시험: '연습이 끝났어요' → 처음 화면 → 누름 장치가 '취소' 위에서 기다리는 대기 화면이 다시 떴다.
    final api = await _pumpKiosk(tester);
    await tester.tap(find.byKey(const ValueKey('strip-microwave')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('해동'));
    await tester.pump();
    await tester.tap(find.text('누르기'));
    await tester.pump();
    api.statusResult = const KioskStatus(
        running: false, lastJobId: 'job-1', lastStatus: 'succeeded', lastExecutionMode: 'mock', lastOutcome: 'success');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.byType(KioskDoneView), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('done-home')));
    await tester.pump();
    api.statusResult = const KioskStatus(
      running: false,
      lastJobId: 'job-1',
      lastStatus: 'succeeded',
      lastExecutionMode: 'mock',
      lastOutcome: 'success',
      holdState: 'hovering_stop',
      holdApplianceId: 'microwave',
      holdStopButton: '취소',
      holdExecutionMode: 'mock',
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(KioskHoldView), findsNothing);
    expect(find.byType(KioskIdleView), findsOneWidget);
    // 대기 중 다른 실행(공기청정기 켜기)으로 마지막 실행 번호가 바뀌어도 닫은 연습 대기는 다시 뜨지 않는다(10/24 실패널).
    api.statusResult = const KioskStatus(
      running: false,
      lastJobId: 'job-air',
      lastStatus: 'succeeded',
      lastExecutionMode: 'real',
      lastOutcome: 'success',
      holdState: 'hovering_stop',
      holdApplianceId: 'microwave',
      holdStopButton: '취소',
      holdExecutionMode: 'mock',
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(KioskHoldView), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
