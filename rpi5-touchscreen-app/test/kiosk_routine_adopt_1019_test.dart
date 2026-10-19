// 검토 10/19 — 쉬다가 루틴의 2번째 구간에서 알아챈 실행은 루틴 첫 번호를 따라간다(본체 /status·GET /jobs의 routine_run_id).
//
// 예전: /status의 구간 번호(job_id)를 이어받아 GET /jobs/{구간 번호}만 물었고, 그 구간이 끝나면 루틴이 다음 구간을 이어 가는데도
// 결과 화면('끝났어요')으로 갔다. 정지도 본체 전체 /stop만 보냈다.
// 이제: /status에 routine_run_id가 있으면 그 번호를, 구간 번호만 알았으면 GET /jobs의 routine_run_id로 갈아타 루틴 전체가 끝날 때까지
// 하는 중으로 보이고, 정지는 그 루틴만 멈추는 경로로. 옛 본체(필드 없음)는 종전처럼. 전부 모의다.
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

const _routine = {
  'routine_run_id': 'job-1',
  'routine_status': 'running',
  'routine_segment': 2,
  'routine_segment_job_id': 'job-2',
};

/// /status — 루틴 2번째 구간이 누르는 중. [withRoutine]이 거짓이면 구간 번호만 싣는다(조회로만 루틴을 안다).
KioskStatus _statusSegment2({bool withRoutine = true}) => KioskStatus.fromJson({
      'running': true,
      'job_id': 'job-2',
      'current_button': '시작',
      'appliance_id': 'microwave',
      'execution_mode': 'real',
      if (withRoutine) ..._routine,
    });

/// GET /jobs/job-2 — 그 구간은 끝났다(루틴은 이어 간다).
final _segment2Done = KioskStatus.fromJson({
  'running': false,
  'finished': true,
  'last_job_id': 'job-2',
  'last_status': 'succeeded',
  'last_outcome': 'success',
  'last_execution_mode': 'real',
  'last_appliance_id': 'microwave',
  ..._routine,
});

/// GET /jobs/job-1 — 루틴 전체. [ended]면 끝났다.
KioskStatus _root({bool ended = false}) => KioskStatus.fromJson(ended
    ? {
        'running': false,
        'finished': true,
        'last_job_id': 'job-1',
        'last_status': 'succeeded',
        'last_outcome': 'success',
        'last_execution_mode': 'real',
        'last_appliance_id': 'microwave',
        ..._routine,
        'routine_status': 'succeeded',
      }
    : {
        'running': true,
        'finished': false,
        'job_id': 'job-1',
        ..._routine,
        'routine_segment': 3,
        'routine_segment_job_id': 'job-3',
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

Future<void> _poll(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 2));
  await tester.pump();
}

Future<void> _adoptAtSegment2(WidgetTester tester, FakeKioskApi api, {required bool statusHasRoutine}) async {
  var rootEnded = false;
  api.jobResult = (id) => switch (id) {
        'job-2' => KioskJobLookup.found(_segment2Done),
        'job-1' => KioskJobLookup.found(_root(ended: rootEnded)),
        _ => const KioskJobLookup.unknown(),
      };
  api.statusResult = _statusSegment2(withRoutine: statusHasRoutine);
  await _poll(tester);
  expect(find.byType(KioskExecutingView), findsOneWidget);

  // 2번째 구간이 끝나고 루틴은 3번째 구간을 이어 간다 — /status는 아직 구간 번호를 보일 수 있다.
  for (var i = 0; i < 3; i++) {
    await _poll(tester);
    await tester.pump(const Duration(milliseconds: 900));
  }
  expect(find.byType(KioskDoneView), findsNothing, reason: '구간 하나의 끝은 루틴의 끝이 아니다');
  expect(find.byType(KioskExecutingView), findsOneWidget);
  expect(api.jobLookups.last, 'job-1', reason: '루틴 첫 번호를 따라간다');

  await tester.tap(find.byType(KioskStopButton));
  await tester.pump();
  expect(api.routineStops, ['job-1'], reason: '정지는 그 루틴만 멈추는 경로로');

  rootEnded = true;
  api.statusResult = _base;
  await _poll(tester);
  await tester.pump(const Duration(milliseconds: 900));
  expect(find.byType(KioskDoneView), findsOneWidget, reason: '루틴 전체가 끝나야 결과 화면');
}

void main() {
  testWidgets('/status가 루틴 첫 번호를 실으면 2번째 구간에서 이어받아도 루틴이 끝날 때까지 하는 중', (tester) async {
    final api = await _pumpKiosk(tester);
    await _adoptAtSegment2(tester, api, statusHasRoutine: true);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('구간 번호만 알았으면 GET /jobs의 routine_run_id로 갈아탄다', (tester) async {
    final api = await _pumpKiosk(tester);
    await _adoptAtSegment2(tester, api, statusHasRoutine: false);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('옛 본체(루틴 필드 없음)는 종전처럼 그 실행이 끝나면 결과 화면', (tester) async {
    final api = await _pumpKiosk(tester);
    api.jobResult = (id) => id == 'job-2'
        ? KioskJobLookup.found(const KioskStatus(
            running: false, finished: true, lastJobId: 'job-2', lastStatus: 'succeeded', lastOutcome: 'success'))
        : const KioskJobLookup.unknown();
    api.statusResult = _statusSegment2(withRoutine: false);
    await _poll(tester);
    expect(find.byType(KioskExecutingView), findsOneWidget);
    await _poll(tester);
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.byType(KioskDoneView), findsOneWidget);
    expect(api.jobLookups.toSet(), {'job-2'});
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
