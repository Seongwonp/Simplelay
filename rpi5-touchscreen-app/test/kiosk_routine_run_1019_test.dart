// 검토 10/19 — 루틴 실행은 첫 실행 번호의 GET /jobs가 루틴 전체 수명이다(본체 routine_run_id 등).
//
// 예전: 구간 사이 기다림에 앞 구간의 버튼을 '누르고 있어요'로 계속 보였고, 다음 구간에 앞 구간의 누른 버튼·칸 수가 섞였다.
// 실행 번호 조회가 잠깐 실패하면 /status로 보는데, 루틴이 도는 동안 /status는 구간 번호만 내놓아 남의 실행처럼 세다
// '어떻게 됐는지 확인하지 못했어요'로 빠졌다. 정지는 본체 전체 /stop만 보냈다.
// 이제: 루틴이면 지금 차례를 말하고, 구간 사이는 '다음 차례를 기다리는 중', 구간이 바뀌면 그 구간 진행만 보인다.
// 끝은 finished=true일 때만. 정지는 그 루틴만 멈추는 /routines/runs/{id}/stop, 받지 않으면 /stop. 전부 모의다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/run_frame.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

const _base = KioskStatus(running: false, lastJobId: 'job-0', lastOutcome: 'success', lastStatus: 'succeeded');

Map<String, dynamic> _routine({int segment = 1, String segmentJob = 'job-1'}) => {
      'routine_run_id': 'job-1',
      'routine_segment': segment,
      'routine_segment_job_id': segmentJob,
    };

/// 루틴이 돌고 지금 구간이 누르는 중.
KioskStatus _live({int segment = 1, String segmentJob = 'job-1', String button = '해동', int? total, int? done}) =>
    KioskStatus.fromJson({
      'running': true,
      'finished': false,
      'job_id': 'job-1',
      'routine_status': 'running',
      'current_button': button,
      'appliance_id': 'microwave',
      'execution_mode': 'real',
      if (total != null) 'total_steps': total,
      if (done != null) 'completed_steps': done,
      ..._routine(segment: segment, segmentJob: segmentJob),
    });

/// 루틴이 돌지만 구간 사이(다음 구간을 기다림) — 진행 필드가 없다.
KioskStatus _between({int segment = 1}) => KioskStatus.fromJson({
      'running': true,
      'finished': false,
      'job_id': 'job-1',
      'routine_status': 'running',
      ..._routine(segment: segment),
    });

KioskStatus _ended(String status, String outcome) => KioskStatus.fromJson({
      'running': false,
      'finished': true,
      'last_job_id': 'job-1',
      'last_status': status,
      'last_outcome': outcome,
      'last_execution_mode': 'real',
      'last_appliance_id': 'microwave',
      'routine_status': status,
      ..._routine(segment: 2, segmentJob: 'job-2'),
    });

Future<FakeKioskApi> _pumpKiosk(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final api = FakeKioskApi()
    ..applianceList = [kMicrowaveAppliance]
    ..statusResult = _base;
  await tester.pumpWidget(MaterialApp(home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream())));
  await tester.pump();
  await tester.pump();
  return api;
}

Future<void> _start(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('strip-microwave')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text('해동'));
  await tester.pump();
  await tester.tap(find.text('누르기'));
  await tester.pump();
}

Future<void> _poll(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 2));
  await tester.pump();
}

KioskExecutingView _exec(WidgetTester tester) => tester.widget<KioskExecutingView>(find.byType(KioskExecutingView));

void main() {
  testWidgets('루틴은 지금 차례를 말하고, 구간 사이는 기다리는 중, 다음 구간은 그 구간 진행만, 끝은 finished일 때', (tester) async {
    final api = await _pumpKiosk(tester);
    var job = _live();
    api.jobResult = (id) => id == 'job-1' ? KioskJobLookup.found(job) : const KioskJobLookup.unknown();
    // /status는 루틴이 도는 동안 구간 번호만 내놓는다.
    api.statusResult = const KioskStatus(running: true, jobId: 'job-1', applianceId: 'microwave', currentButton: '해동');
    await _start(tester);
    await _poll(tester);
    expect(find.byType(KioskExecutingView), findsOneWidget);
    expect(find.text('루틴 1번째 차례'), findsOneWidget);

    job = _between();
    api.statusResult = const KioskStatus(running: false);
    await _poll(tester);
    expect(find.byType(KioskExecutingView), findsOneWidget, reason: '구간 사이도 루틴은 하는 중');
    expect(_exec(tester).currentButton, isNull, reason: '앞 구간의 버튼을 지금 누르는 것처럼 보이지 않는다');
    expect(find.text(kExecRoutineWaiting), findsOneWidget);
    expect(find.byType(KioskStopButton), findsOneWidget);

    job = _live(segment: 2, segmentJob: 'job-2', button: '시작', total: 2, done: 0);
    api.statusResult = const KioskStatus(running: true, jobId: 'job-2', applianceId: 'microwave', currentButton: '시작');
    await _poll(tester);
    expect(find.text('루틴 2번째 차례'), findsOneWidget);
    expect(_exec(tester).currentButton, '시작');
    expect(_exec(tester).doneButtons, isEmpty, reason: '앞 구간에서 누른 버튼을 이 구간의 누른 칸으로 세지 않는다');

    job = _ended('failed', 'failed');
    api.statusResult = const KioskStatus(running: false, lastJobId: 'job-1', lastOutcome: 'failed', lastStatus: 'failed');
    await _poll(tester);
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.byType(KioskDoneView), findsOneWidget);
    expect(tester.widget<KioskDoneView>(find.byType(KioskDoneView)).success, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('끝났다고 하지 않은(finished=false) 답은 결과로 보지 않는다', (tester) async {
    final api = await _pumpKiosk(tester);
    api.jobResult = (_) => KioskJobLookup.found(KioskStatus.fromJson({
          'running': false,
          'finished': false,
          'last_job_id': 'job-1',
          'last_status': 'succeeded',
          'last_outcome': 'success',
          'routine_status': 'running',
          ..._routine(),
        }));
    await _start(tester);
    await _poll(tester);
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.byType(KioskDoneView), findsNothing);
    expect(find.byType(KioskExecutingView), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('루틴을 따라가다 실행 번호 조회가 잠깐 실패해도 /status의 구간 번호를 남의 실행으로 세지 않는다', (tester) async {
    final api = await _pumpKiosk(tester);
    var lookupFails = false;
    api.jobResult = (_) => lookupFails ? const KioskJobLookup.unsupported() : KioskJobLookup.found(_between());
    api.statusResult = const KioskStatus(running: true, jobId: 'job-2', applianceId: 'microwave', currentButton: '시작');
    await _start(tester);
    await _poll(tester);
    lookupFails = true;
    for (var i = 0; i < 6; i++) {
      await _poll(tester);
    }
    expect(find.byType(KioskDoneView), findsNothing);
    expect(find.byType(KioskExecutingView), findsOneWidget);
    lookupFails = false;
    api.jobResult = (_) => KioskJobLookup.found(_ended('succeeded', 'success'));
    await _poll(tester);
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.byType(KioskDoneView), findsOneWidget);
    expect(tester.widget<KioskDoneView>(find.byType(KioskDoneView)).success, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('루틴 정지는 그 루틴만 멈추는 경로로, 본체가 받지 않으면 본체 전체 정지로', (tester) async {
    final api = await _pumpKiosk(tester);
    api.jobResult = (_) => KioskJobLookup.found(_between());
    await _start(tester);
    await _poll(tester);
    await tester.tap(find.byType(KioskStopButton));
    await tester.pump();
    expect(api.routineStops, ['job-1']);
    expect(api.stopCalls, 0);

    api.routineStopError = KioskApiException(409, '진행 중인 루틴 실행이 아니에요');
    await tester.tap(find.byType(KioskStopButton));
    await tester.pump();
    expect(api.routineStops, ['job-1', 'job-1']);
    expect(api.stopCalls, 1);
    expect(find.byKey(const ValueKey('exec-stop-failed-band')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
