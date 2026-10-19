// 검토 10/19(코어 4차) — 접수 응답을 잃었을 때의 정직성과 정지.
//
// 1. 접수 응답 전에 누른 정지는 응답이 끊기거나(시간 초과) 본체에서 실행을 이어받아도 잃지 않는다 — 본체가 쉬거나
//    그 실행이 끝날 때까지 /stop을 다시 보낸다. 예전에는 성공 응답에서만 다시 보냈고, 이어받기가 정지 표시를 지웠다.
// 3. /approve·/execute-buttons 응답이 끊기면 '못 보냈다'로 끝내지 않는다 — 시작됐을 수 있다고 말하고 정지 단추를 두고,
//    /status에서 도는 실행을 이어받는다. 예전에는 바로 결과 화면('어떻게 됐는지 몰라요')으로 가 정지 단추가 사라졌다.
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

KioskStatus _running(String jobId) =>
    KioskStatus(running: true, jobId: jobId, applianceId: 'microwave', lastJobId: 'job-0');

KioskStatus _ended(String jobId, {String outcome = 'stopped', String status = 'safety_stopped'}) => KioskStatus(
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

KioskExecStop _stopState(WidgetTester tester) =>
    tester.widget<KioskExecutingView>(find.byType(KioskExecutingView)).stopState;

void main() {
  group('1. 접수 응답 전 정지 — 응답을 잃어도 잃지 않는다', () {
    testWidgets('승인 응답이 끊겨도 본체에서 도는 실행을 이어받아 정지를 다시 보내고, 끝날 때까지 되풀이한다', (tester) async {
      final api = await _pumpKiosk(tester, suggestions: [_sug]);
      final pending = Completer<KioskJobAccepted>();
      api.approvalPending = pending;
      await _approve(tester, api);
      await tester.tap(_stopButton);
      await tester.pump();
      expect(api.stopCalls, 1, reason: '첫 정지는 접수 전이라 아무것도 멈추지 못했다');

      // 본체는 접수했지만 응답이 끊겼다.
      api.statusResult = _running('job-9');
      pending.completeError(TimeoutException('approve'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(KioskDoneView), findsNothing);
      expect(find.byType(KioskExecutingView), findsOneWidget);
      expect(_stopState(tester), KioskExecStop.stopping);

      await _poll(tester);
      expect(api.stopCalls, greaterThanOrEqualTo(2), reason: '이어받은 실행에 정지를 다시 보낸다');
      final afterAdopt = api.stopCalls;
      await _poll(tester);
      expect(api.stopCalls, greaterThan(afterAdopt), reason: '아직 돌면 또 보낸다');

      api.statusResult = _ended('job-9');
      await _poll(tester);
      await tester.pump(const Duration(milliseconds: 900));
      final ended = api.stopCalls;
      expect(find.byType(KioskDoneView), findsOneWidget);
      await _poll(tester);
      await _poll(tester);
      expect(api.stopCalls, ended, reason: '그 실행이 끝나면 더 보내지 않는다');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('직접 누르기 응답이 오류여도 같다 — 정지는 본체가 쉴 때까지 남는다', (tester) async {
      final api = await _pumpKiosk(tester);
      final pending = Completer<KioskJobAccepted>();
      api.executePending.add(pending);
      await _pressManual(tester);
      await tester.tap(_stopButton);
      await tester.pump();
      expect(api.stopCalls, 1);

      api.statusResult = _running('job-5');
      pending.completeError(Exception('connection reset'));
      await tester.pump();
      await tester.pump();
      await _poll(tester);
      expect(api.stopCalls, greaterThanOrEqualTo(2));

      api.statusResult = _base; // 본체가 쉰다 — 결과가 바뀌지 않았다
      await _poll(tester);
      final idle = api.stopCalls;
      await _poll(tester);
      await _poll(tester);
      await _poll(tester);
      expect(api.stopCalls, idle);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('job_id를 받은 뒤에도 그 실행이 끝날 때까지 정지를 되풀이한다', (tester) async {
      final api = await _pumpKiosk(tester, suggestions: [_sug]);
      final pending = Completer<KioskJobAccepted>();
      api.approvalPending = pending;
      await _approve(tester, api);
      await tester.tap(_stopButton);
      await tester.pump();
      api.statusResult = _running('job-1');
      pending.complete(const KioskJobAccepted(jobId: 'job-1'));
      await tester.pump();
      await tester.pump();
      expect(api.stopCalls, 2);
      await _poll(tester);
      expect(api.stopCalls, 3, reason: '첫 재전송이 접수 직전 창에 걸렸을 수 있다 — 아직 돌면 또 보낸다');
      api.statusResult = _ended('job-1');
      await _poll(tester);
      final ended = api.stopCalls;
      await tester.pump(const Duration(milliseconds: 900));
      await _poll(tester);
      expect(api.stopCalls, ended);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('3. 접수 응답을 잃으면 — 시작됐을 수 있다', () {
    testWidgets("승인 응답이 끊기면 결과 화면으로 가지 않고 정지 단추를 두며 '시작됐을 수 있어요'를 말한다", (tester) async {
      final api = await _pumpKiosk(tester, suggestions: [_sug]);
      api.executeError = TimeoutException('approve');
      await _approve(tester, api);
      await tester.pump();
      expect(find.byType(KioskDoneView), findsNothing);
      expect(find.byType(KioskExecutingView), findsOneWidget);
      expect(tester.widget<ElevatedButton>(_stopButton).onPressed, isNotNull);
      expect(find.text(kAdmitUnknownMessage), findsOneWidget);

      // 본체에서 도는 실행을 이어받고, 그 결과를 보인다.
      api.statusResult = _running('job-7');
      await _poll(tester);
      expect(find.byType(KioskExecutingView), findsOneWidget);
      api.statusResult = _ended('job-7', outcome: 'success', status: 'succeeded');
      await _poll(tester);
      await tester.pump(const Duration(milliseconds: 900));
      expect(find.byType(KioskDoneView), findsOneWidget);
      expect(tester.widget<KioskDoneView>(find.byType(KioskDoneView)).success, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('직접 누르기 응답이 끊겨도 정지 단추를 두고, 그 사이 끝난 실행 결과를 보인다', (tester) async {
      final api = await _pumpKiosk(tester);
      api.executeError = Exception('connection reset');
      await _pressManual(tester);
      await tester.pump();
      expect(find.byType(KioskDoneView), findsNothing);
      expect(tester.widget<ElevatedButton>(_stopButton).onPressed, isNotNull);
      api.statusResult = _ended('job-8', outcome: 'failed', status: 'failed');
      await _poll(tester);
      await tester.pump(const Duration(milliseconds: 900));
      expect(find.byType(KioskDoneView), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('본체가 계속 쉬고 결과도 그대로면 잠시 뒤 결과 화면으로 — 정지 단추가 영원히 남지 않는다', (tester) async {
      final api = await _pumpKiosk(tester, suggestions: [_sug]);
      api.executeError = TimeoutException('approve');
      await _approve(tester, api);
      await tester.pump();
      await _poll(tester);
      expect(find.byType(KioskExecutingView), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        await _poll(tester);
      }
      expect(find.byType(KioskDoneView), findsOneWidget);
      expect(tester.widget<KioskDoneView>(find.byType(KioskDoneView)).reason, KioskFailureReason.serverLost);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('옛 본체에서 찾지 못하고 결과 화면으로 가면 남은 정지를 버린다 — 그 뒤 폰이 시작한 실행을 멈추지 않는다(검토 10/19 코어 6차 #1)',
        (tester) async {
      final api = await _pumpKiosk(tester, suggestions: [_sug]);
      api.executeError = TimeoutException('approve');
      await _approve(tester, api);
      await tester.pump();
      await tester.tap(_stopButton);
      await tester.pump();
      for (var i = 0; i < 4; i++) {
        await _poll(tester);
      }
      expect(find.byType(KioskDoneView), findsOneWidget);
      final given = api.stopCalls;

      // 정지 대기 창(20초) 안에 다른 기기가 실행을 시작했다 — 결과 화면이 그 실행을 이어받아도 내 정지를 보내지 않는다.
      api.statusResult = _running('job-phone');
      await _poll(tester);
      await _poll(tester);
      expect(find.byType(KioskExecutingView), findsOneWidget);
      expect(api.stopCalls, given, reason: '찾지 못하고 포기한 접수의 정지를 남의 실행에 보내면 안 된다');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('본체가 분명히 거절하면(409) 종전처럼 바로 결과 화면', (tester) async {
      final api = await _pumpKiosk(tester, suggestions: [_sug]);
      api.executeError = KioskApiException(409, '다른 작업을 실행 중이에요');
      await _approve(tester, api);
      await tester.pump();
      expect(find.byType(KioskDoneView), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
