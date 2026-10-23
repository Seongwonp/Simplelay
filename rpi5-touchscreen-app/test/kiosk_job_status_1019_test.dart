// 검토 10/19(코어 5차 #4) — 내 실행의 결과는 실행 번호로 묻는다(GET /jobs/{job_id}).
//
// 예전: 끝난 결과는 /status의 마지막 한 건(last_job_id)뿐이라, 내 실행이 끝난 뒤 폴링 사이에 다른 실행(폰·자동 실행)이
// 시작해 끝나면 내 결과를 잃고 몇 번 뒤 '어떻게 됐는지 확인하지 못했어요'로 빠졌다.
// 이제: 진행·결과는 /jobs/{job_id}로, 기기 전체 값(비상정지·대기·자동 실행)은 /status로. 옛 본체는 종전처럼 /status.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

const _base = KioskStatus(running: false, lastJobId: 'job-0', lastOutcome: 'success', lastStatus: 'succeeded');

/// 내 실행 다음에 시작해 끝난 다른 실행(폰) — /status의 마지막 한 건이 이것으로 바뀌었다.
const _otherEnded = KioskStatus(
    running: false,
    lastJobId: 'job-2',
    lastApplianceId: 'microwave',
    lastOutcome: 'failed',
    lastStatus: 'failed',
    lastExecutionMode: 'real',
    reportsStopJobId: true);

const _mineRunning = KioskStatus(running: true, jobId: 'job-1', applianceId: 'microwave', currentButton: '해동');

KioskStatus _mineEnded({String outcome = 'success', String status = 'succeeded'}) => KioskStatus(
    running: false,
    lastJobId: 'job-1',
    lastApplianceId: 'microwave',
    lastOutcome: outcome,
    lastStatus: status,
    lastExecutionMode: 'real',
    reportsStopJobId: true);

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

Future<void> _pressManual(WidgetTester tester) async {
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

KioskDoneView _done(WidgetTester tester) => tester.widget<KioskDoneView>(find.byType(KioskDoneView));

void main() {
  testWidgets('내 실행이 끝난 뒤 다른 실행이 끝나 /status가 바뀌어도 내 결과를 보인다', (tester) async {
    final api = await _pumpKiosk(tester);
    var mine = _mineRunning;
    api.jobResult = (id) => id == 'job-1' ? KioskJobLookup.found(mine) : const KioskJobLookup.unknown();
    api.statusResult = _mineRunning;
    await _pressManual(tester);
    await _poll(tester);
    expect(find.byType(KioskExecutingView), findsOneWidget);

    mine = _mineEnded();
    api.statusResult = _otherEnded;
    await _poll(tester);
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.byType(KioskDoneView), findsOneWidget);
    expect(_done(tester).success, isTrue, reason: '다른 실행(job-2 실패)이 아니라 내 실행(job-1 성공)의 결과');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('본체가 내 실행을 모른다고 하면(재시작 등) 몇 번 뒤 고착 대신 결과 화면', (tester) async {
    final api = await _pumpKiosk(tester);
    api.jobResult = (_) => const KioskJobLookup.unknown();
    api.statusResult = _otherEnded;
    await _pressManual(tester);
    for (var i = 0; i < 5; i++) {
      await _poll(tester);
    }
    expect(find.byType(KioskDoneView), findsOneWidget);
    expect(_done(tester).reason, KioskFailureReason.serverLost);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
