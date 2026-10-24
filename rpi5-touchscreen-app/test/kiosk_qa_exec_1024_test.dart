// 키오스크 QA(2026-10-24) — 저장된 동작(루틴) 실행 화면의 버튼 수. 본체는 승인 명령 수를 단계 수로 실어 '30초 → 시작'(명령 하나에
// 버튼 둘)이 '누를 버튼 1개 중 1번째'로 보였다. 카드에 묶인 버튼으로 센다. 첫 차례뿐이면 '루틴 1번째 차례'를 말하지 않는다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/status_band.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

const _card = KioskSuggestion(
  id: 'card-30',
  purpose: "'30초 데우기' 루틴을 실행할까요?",
  occurrences: 0,
  applianceId: 'microwave',
  routineId: 'rt-30s',
  routineName: '30초 데우기',
  reason: '직접 실행을 눌렀어요',
  scenarioId: 'routine:rt-30s:abc',
  commands: [
    KioskSuggestionCommand(targetId: 'microwave', route: 'physical', buttons: ['30초', '시작'], summary: '전자레인지 30초 → 시작'),
  ],
);

KioskStatus _live(String button, {int done = 0}) => KioskStatus.fromJson({
      'running': true,
      'finished': false,
      'job_id': 'job-1',
      'routine_run_id': 'job-1',
      'routine_status': 'running',
      'routine_segment': 1,
      'routine_segment_job_id': 'job-1',
      'current_button': button,
      'appliance_id': 'microwave',
      'execution_mode': 'mock',
      'total_steps': 1,
      'completed_steps': done,
    });

void main() {
  cardMain();
  testWidgets("루틴 '30초 → 시작'은 누를 버튼 2개 — 첫 차례뿐이면 '루틴 1번째 차례'가 없다", (tester) async {
    tester.view.physicalSize = const Size(800, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = FakeKioskApi()
      ..applianceList = [kMicrowaveAppliance]
      ..suggestionList = [_card];
    var job = _live('30초');
    api.jobResult = (id) => id == 'job-1' ? KioskJobLookup.found(job) : const KioskJobLookup.unknown();
    await tester.pumpWidget(MaterialApp(home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream())));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    api.suggestionList = [];
    await tester.tap(find.byKey(const ValueKey('suggestion-approve')));
    await tester.pump();
    api.statusResult = const KioskStatus(running: true, jobId: 'job-1', applianceId: 'microwave', currentButton: '30초');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.byType(KioskExecutingView), findsOneWidget);
    expect(find.text('누를 버튼 2개 중 1번째'), findsOneWidget);
    expect(find.text('누를 버튼 1개 중 1번째'), findsNothing);
    expect(find.text('루틴 1번째 차례'), findsNothing);

    job = _live('시작');
    api.statusResult = const KioskStatus(running: true, jobId: 'job-1', applianceId: 'microwave', currentButton: '시작');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('누를 버튼 2개 중 2번째'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Finder _band(String label) => find.descendant(of: find.byType(KioskStatusBand), matching: find.text(label));

void cardMain() {
  testWidgets("내가 누른 저장된 동작의 카드는 '확인' — 제안이 아니고 '루틴' 말 없이 '30초 데우기를 할까요?'", (tester) async {
    tester.view.physicalSize = const Size(800, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = FakeKioskApi()
      ..applianceList = [kMicrowaveAppliance]
      ..routinesResult = const [
        KioskRoutine(id: 'rt-30s', name: '30초 데우기', applianceIds: ['microwave'], pressCount: 2),
      ]
      // 서버 근거 줄이 없어도(옛 본체) 키오스크가 직접 누른 것을 안다.
      ..triggerResult = RoutineTriggerResult(suggestion: KioskSuggestion(
        id: _card.id,
        purpose: _card.purpose,
        occurrences: 0,
        applianceId: 'microwave',
        routineId: 'rt-30s',
        routineName: '30초 데우기',
        scenarioId: _card.scenarioId,
        commands: _card.commands,
      ));
    await tester.pumpWidget(MaterialApp(home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream())));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('strip-microwave')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('routine-rt-30s')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(KioskSuggestionView), findsOneWidget);
    expect(_band('확인'), findsOneWidget);
    expect(_band('제안'), findsNothing);
    expect(find.text('30초 데우기를 할까요?'), findsOneWidget);
    expect(find.textContaining('루틴을 실행할까요'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets("스스로 뜬 제안은 그대로 '제안'", (tester) async {
    tester.view.physicalSize = const Size(800, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = FakeKioskApi()
      ..applianceList = [kMicrowaveAppliance]
      ..suggestionList = [
        const KioskSuggestion(id: 's1', purpose: '즉석밥 데워줘', occurrences: 3, applianceId: 'microwave'),
      ];
    await tester.pumpWidget(MaterialApp(home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream())));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(_band('제안'), findsOneWidget);
    expect(_band('확인'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
