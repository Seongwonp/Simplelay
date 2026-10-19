// 검토 10/19 — 실행 화면 정지·접수의 정직성.
//
// 5. /stop의 4xx·5xx는 예외다 — 실행 화면은 정지 단추를 그대로 두고 '정지가 닿지 않았어요'를 말한다. 닿으면 '멈추는 중'.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
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
}
