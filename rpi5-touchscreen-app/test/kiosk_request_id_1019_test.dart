// 검토 10/19(코어 5차 #3) — 접수 응답을 잃은 실행을 요청 번호로 찾는다.
//
// 예전: 응답을 잃으면 그때 /status에서 도는 실행을 무엇이든 내 것으로 이어받았다 — 내 요청이 닿지 않았는데 자동 실행·폰 실행이
// 돌면 그 결과를 내 결과로 보이고, 접수 전에 누른 정지를 그 실행에 다시 보냈다.
// 이제: 접수마다 요청 번호(client_request_id)를 보내고, 응답을 잃으면 GET /jobs/by-request로 내 실행을 찾는다.
// 본체가 모르는 번호라고 하면 남의 실행을 이어받지 않는다. 옛 본체(조회 없음)만 종전처럼 찾는다(kiosk_admission_unknown_1019_test).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/run_frame.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

const _sug = KioskSuggestion(
  id: 's1',
  purpose: '즉석밥 데워줘',
  occurrences: 3,
  applianceId: 'microwave',
);

const _base = KioskStatus(running: false, lastJobId: 'job-0', lastOutcome: 'success', lastStatus: 'succeeded');

/// 그때 도는 남의 실행(자동 실행·폰).
const _foreign = KioskStatus(running: true, jobId: 'job-auto', applianceId: 'microwave', lastJobId: 'job-0');

KioskStatus _ended(String jobId, {String outcome = 'success', String status = 'succeeded'}) => KioskStatus(
    running: false,
    lastJobId: jobId,
    lastApplianceId: 'microwave',
    lastOutcome: outcome,
    lastStatus: status,
    lastExecutionMode: 'real');

Future<FakeKioskApi> _pumpKiosk(WidgetTester tester, {List<KioskSuggestion> suggestions = const []}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final api = FakeKioskApi()
    ..applianceList = [kMicrowaveAppliance]
    ..suggestionList = [...suggestions]
    ..statusResult = _base;
  await tester.pumpWidget(MaterialApp(home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream())));
  await tester.pump();
  await tester.pump();
  return api;
}

Future<void> _approve(WidgetTester tester, FakeKioskApi api) async {
  api.suggestionList = [];
  await tester.tap(find.byKey(const ValueKey('suggestion-approve')));
  await tester.pump();
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

Finder get _stopButton => find.descendant(
    of: find.byType(KioskStopButton), matching: find.byType(ElevatedButton));

final _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

void main() {
  testWidgets('승인·직접 누르기마다 본체 형식에 맞는 새 요청 번호를 보낸다', (tester) async {
    final api = await _pumpKiosk(tester, suggestions: [_sug]);
    await _approve(tester, api);
    api.statusResult = _ended('job-1');
    await _poll(tester);
    await tester.pump(const Duration(milliseconds: 900));
    await tester.tap(find.byKey(const ValueKey('done-home')));
    await tester.pump();
    api.nextJobId = 'job-2';
    await _pressManual(tester);
    expect(api.requestIds, hasLength(2));
    for (final id in api.requestIds) {
      expect(id, isNotNull);
      expect(_idPattern.hasMatch(id!), isTrue, reason: id);
    }
    expect(api.requestIds.first, isNot(api.requestIds.last), reason: '접수마다 새 번호');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('응답을 잃었고 본체가 모르는 번호라고 하면, 그때 도는 남의 실행을 이어받지도 멈추지도 않는다', (tester) async {
    final api = await _pumpKiosk(tester, suggestions: [_sug]);
    final pending = Completer<KioskJobAccepted>();
    api.approvalPending = pending;
    api.requestLookup = (_) => const KioskRequestLookup(KioskRequestLookupKind.unknown);
    await _approve(tester, api);
    await tester.tap(_stopButton);
    await tester.pump();
    expect(api.stopCalls, 1);

    api.statusResult = _foreign;
    pending.completeError(TimeoutException('approve'));
    await tester.pump();
    await tester.pump();
    await _poll(tester);
    expect(api.requestLookups, [api.requestIds.single], reason: '보낸 그 번호로 찾는다');
    expect(api.stopCalls, 1, reason: '남의 실행에 정지를 다시 보내지 않는다');
    expect(find.byType(KioskExecutingView), findsOneWidget);

    await _poll(tester);
    await _poll(tester);
    expect(find.byType(KioskDoneView), findsOneWidget);
    expect(tester.widget<KioskDoneView>(find.byType(KioskDoneView)).reason, KioskFailureReason.serverLost);
    await _poll(tester);
    await _poll(tester);
    expect(api.stopCalls, 1, reason: '결과 화면에서도 남의 실행에 정지를 다시 보내지 않는다');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('응답을 잃어도 본체가 그 번호의 실행을 알려 주면, 그때 도는 다른 실행이 아니라 그 실행의 결과를 보인다', (tester) async {
    final api = await _pumpKiosk(tester);
    api.executeError = Exception('connection reset');
    api.requestLookup = (_) => const KioskRequestLookup(KioskRequestLookupKind.found, 'job-7');
    await _pressManual(tester);
    await tester.pump();
    api.statusResult = _foreign;
    await _poll(tester);
    expect(find.byType(KioskExecutingView), findsOneWidget);

    api.statusResult = _ended('job-7');
    await _poll(tester);
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.byType(KioskDoneView), findsOneWidget);
    expect(tester.widget<KioskDoneView>(find.byType(KioskDoneView)).success, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
