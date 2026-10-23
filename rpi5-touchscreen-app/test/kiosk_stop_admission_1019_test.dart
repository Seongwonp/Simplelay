// 검토 10/19 — 실행 화면 정지·접수의 정직성.
//
// 5. /stop의 4xx·5xx는 예외다 — 실행 화면은 정지 단추를 그대로 두고 '정지 요청 결과를 확인하지 못했어요'를 말한다. 닿으면 '멈추는 중'.
// 1. 접수 응답(job_id) 전에 누른 정지는 job이 오는 대로 다시 보낸다 — 그동안 '멈추는 중'.
// 8. 직접 누르기 확인을 두 번 눌러도 요청은 하나 — 둘째의 409가 첫 실행을 실패 화면 뒤에 숨기지 않는다(화면 접수 관문·세대).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/run_frame.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

const _sug = KioskSuggestion(
  id: 's1',
  purpose: '즉석밥 데워줘',
  occurrences: 3,
  applianceId: 'microwave',
);

Future<FakeKioskApi> _pumpKiosk(WidgetTester tester, {List<KioskSuggestion> suggestions = const []}) async {
  final api = FakeKioskApi()
    ..applianceList = [kMicrowaveAppliance]
    ..suggestionList = [...suggestions];
  await tester.pumpWidget(MaterialApp(home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream())));
  await tester.pump();
  await tester.pump();
  return api;
}

Future<void> _approve(WidgetTester tester, FakeKioskApi api) async {
  api.suggestionList = [];
  await tester.tap(find.byKey(const ValueKey('suggestion-approve')));
  await tester.pump();
  expect(find.byType(KioskExecutingView), findsOneWidget);
}

Finder get _stopButton => find.descendant(
    of: find.byType(KioskStopButton), matching: find.byType(ElevatedButton));

KioskExecStop _stopState(WidgetTester tester) =>
    tester.widget<KioskExecutingView>(find.byType(KioskExecutingView)).stopState;

void main() {
  group('5. 정지 응답 확인', () {
    test('/stop이 503이면 예외 — 보냈다고 하지 않는다', () async {
      final calls = <String>[];
      await expectLater(
        http.runWithClient(
            () => KioskApiService(baseUrl: 'http://hub.test').stop(),
            () => MockClient((req) async {
                  calls.add(req.url.path);
                  return http.Response('{"detail":"busy"}', 503);
                })),
        throwsA(isA<KioskApiException>().having((e) => e.statusCode, 'statusCode', 503)),
      );
      expect(calls, ['/stop']);
    });

    test('/stop이 200이면 그대로 끝난다', () async {
      await http.runWithClient(() => KioskApiService(baseUrl: 'http://hub.test').stop(),
          () => MockClient((_) async => http.Response('{}', 200)));
    });

    testWidgets('실행 화면 정지가 거절되면 정지 단추를 그대로 두고 닿지 않았다고 말한다', (tester) async {
      final api = await _pumpKiosk(tester, suggestions: [_sug]);
      await _approve(tester, api);
      await tester.pump();
      api.stopError = KioskApiException(503, 'busy');
      await tester.tap(_stopButton);
      await tester.pump();
      expect(api.stopCalls, 1);
      expect(find.byType(KioskExecutingView), findsOneWidget);
      expect(_stopState(tester), KioskExecStop.failed);
      expect(find.byKey(const ValueKey('exec-stop-failed-band')), findsOneWidget);
      expect(find.text(kExecStopFailed), findsOneWidget);
      expect(tester.widget<ElevatedButton>(_stopButton).onPressed, isNotNull);

      // 다시 누르면 다시 보낸다 — 닿으면 '멈추는 중'.
      api.stopError = null;
      await tester.tap(_stopButton);
      await tester.pump();
      expect(api.stopCalls, 2);
      expect(_stopState(tester), KioskExecStop.stopping);
      expect(find.byKey(const ValueKey('exec-stopping-band')), findsOneWidget);
      expect(find.text('멈추는 중'), findsOneWidget);
    });
  });

  group('8. 직접 누르기 두 번 — 요청 하나만', () {
    testWidgets('확인 창 누르기를 다시 그리기 전에 두 번 눌러도 한 번만 맡긴다', (tester) async {
      tester.view.physicalSize = const Size(800, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final pressed = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: KioskManualView(
              appliance: kMicrowaveAppliance, onExecute: (b) => pressed.add(b.label), onCancel: () {}),
        ),
      ));
      await tester.tap(find.text('시작'));
      await tester.pump();
      await tester.tap(find.text('누르기'));
      await tester.tap(find.text('누르기'));
      await tester.pump();
      expect(pressed, ['시작']);
    });

    testWidgets('두 번째 요청의 409가 첫 실행을 실패 화면 뒤에 숨기지 않는다', (tester) async {
      final api = await _pumpKiosk(tester);
      final first = Completer<KioskJobAccepted>();
      final second = Completer<KioskJobAccepted>();
      api.executePending.addAll([first, second]);
      await tester.tap(find.byKey(const ValueKey('strip-microwave')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('해동'));
      await tester.pump();
      await tester.tap(find.text('누르기'));
      await tester.tap(find.text('누르기'));
      await tester.pump();
      if (api.executeCalls >= 2) second.completeError(KioskApiException(409, '이미 실행 중이에요'));
      first.complete(const KioskJobAccepted(jobId: 'job-1'));
      await tester.pump();
      await tester.pump();
      expect(api.executeCalls, 1);
      expect(find.byType(KioskExecutingView), findsOneWidget);
      expect(find.byType(KioskDoneView), findsNothing);
    });
  });

  group('1. 접수 응답 전 정지 — job이 오면 다시 멈춘다', () {
    testWidgets('승인 응답 전에 누른 정지는 job_id가 오는 대로 한 번 더 보내고, 그동안 멈추는 중', (tester) async {
      final api = await _pumpKiosk(tester, suggestions: [_sug]);
      final pending = Completer<KioskJobAccepted>();
      api.approvalPending = pending;
      await _approve(tester, api);
      await tester.tap(_stopButton);
      await tester.pump();
      expect(api.stopCalls, 1);
      expect(_stopState(tester), KioskExecStop.stopping);
      expect(find.text('멈추는 중'), findsOneWidget);

      pending.complete(const KioskJobAccepted(jobId: 'job-1'));
      await tester.pump();
      await tester.pump();
      expect(api.stopCalls, 2);
      expect(find.byType(KioskExecutingView), findsOneWidget);
      expect(_stopState(tester), KioskExecStop.stopping);
    });

    testWidgets('직접 누르기도 같다 — 첫 정지가 닿지 않았어도 job이 오면 다시 보낸다', (tester) async {
      final api = await _pumpKiosk(tester);
      final pending = Completer<KioskJobAccepted>();
      api.executePending.add(pending);
      await tester.tap(find.byKey(const ValueKey('strip-microwave')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('해동'));
      await tester.pump();
      await tester.tap(find.text('누르기'));
      await tester.pump();
      api.stopError = KioskApiException(503, 'busy');
      await tester.tap(_stopButton);
      await tester.pump();
      expect(api.stopCalls, 1);
      expect(_stopState(tester), KioskExecStop.failed);

      api.stopError = null;
      pending.complete(const KioskJobAccepted(jobId: 'job-1'));
      await tester.pump();
      await tester.pump();
      expect(api.stopCalls, 2);
      expect(_stopState(tester), KioskExecStop.stopping);
    });

    testWidgets('job_id를 안 뒤의 정지는 한 번만 보낸다', (tester) async {
      final api = await _pumpKiosk(tester, suggestions: [_sug]);
      await _approve(tester, api);
      await tester.pump();
      await tester.tap(_stopButton);
      await tester.pump();
      await tester.pump();
      expect(api.stopCalls, 1);
    });
  });
}
