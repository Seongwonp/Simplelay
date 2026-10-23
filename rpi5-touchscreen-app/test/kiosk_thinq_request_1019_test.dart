// 검토 10/19 — LG 가전 상세의 직접 조작에 요청 번호(client_request_id)를 싣는다.
//
// 예전: 확인 → 바꾸기에서 응답을 잃으면(시간 초과·끊김) '됐는지 확인하지 못했어요'만 말하고 끝났다 — 본체가 이미 받아 보낸 명령의
// 실행 화면(정지 단추·결과)을 잃었다. 확인 단추를 빨리 두 번 누르면 같은 조작이 두 번 나갔다.
// 이제: 조작마다 새 요청 번호를 싣고, 보내기 전에 보내는 중으로 바꿔 다시 누름을 막는다. 응답을 잃으면 그 번호로
// GET /jobs/by-request를 물어 접수됐으면 그 실행을 따라가고, 본체가 모른다고 하면 받지 못했다고 말한다.
// 옛 본체(번호 필드를 모름 → 422)에는 번호 없이 한 번 다시 보낸다. 전부 모의다.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/thinq.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

final _purifier = applianceFromServerJson({
  'id': 'air_purifier',
  'name': '공기청정기',
  'category': 'other',
  'rows': 0,
  'cols': 0,
  'buttons': <dynamic>[],
  'control_path': 'thinq',
  'can_execute': true,
  'readiness': 'operable',
});

final _status = KioskThinqStatus(state: const {
  'operation': {'airPurifierOperationMode': 'POWER_ON'},
  'airFlow': {'windStrength': 'LOW'},
}, executionMode: 'real', readAt: DateTime(2026, 10, 19, 9));

Future<FakeKioskApi> _openPanel(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final api = FakeKioskApi()
    ..applianceList = [kMicrowaveAppliance, _purifier]
    ..thinqStatusResult = _status
    ..nextJobId = 'job-thinq';
  await tester.pumpWidget(MaterialApp(home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream())));
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.byKey(const ValueKey('strip-air_purifier')));
  await tester.pump();
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('thinq-set-set_wind_strength-HIGH')));
  await tester.pump();
  return api;
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('응답을 잃으면 같은 요청 번호로 찾아 접수된 실행을 따라간다', (tester) async {
    final api = await _openPanel(tester);
    api
      ..thinqCommandError = TimeoutException('lost')
      ..requestLookup = (id) => KioskRequestLookup(KioskRequestLookupKind.found, 'job-found');
    await tester.tap(find.byKey(const ValueKey('thinq-confirm-ok')));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(api.thinqCommands, hasLength(1), reason: '다시 보내지 않는다');
    final sent = api.thinqRequestIds.single;
    expect(sent, isNotNull);
    expect(RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(sent!), isTrue);
    expect(api.requestLookups, [sent]);
    expect(find.byType(KioskExecutingView), findsOneWidget);
    expect(find.text(kThinqUnknownOutcome), findsNothing);
    await _close(tester);
  });

  testWidgets('본체가 그 번호를 모르면 받지 못했다고 말하고 상세에 남는다', (tester) async {
    final api = await _openPanel(tester);
    api
      ..thinqCommandError = TimeoutException('lost')
      ..requestLookup = (id) => const KioskRequestLookup(KioskRequestLookupKind.unknown);
    await tester.tap(find.byKey(const ValueKey('thinq-confirm-ok')));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.byType(KioskExecutingView), findsNothing);
    expect(find.text(kThinqNotReceived), findsOneWidget);
    await _close(tester);
  });

  testWidgets('옛 본체(번호 조회 없음)·조회 실패면 종전처럼 됐는지 모른다고 말한다', (tester) async {
    final api = await _openPanel(tester);
    api.thinqCommandError = TimeoutException('lost'); // 조회는 기본 unsupported
    await tester.tap(find.byKey(const ValueKey('thinq-confirm-ok')));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.byType(KioskExecutingView), findsNothing);
    expect(find.text(kThinqUnknownOutcome), findsOneWidget);
    await _close(tester);
  });

  testWidgets('바꾸기를 빨리 두 번 눌러도 한 번만 보낸다', (tester) async {
    final api = await _openPanel(tester);
    final reply = Completer<KioskJobAccepted>();
    api.thinqCommandPending = reply;
    final ok = find.byKey(const ValueKey('thinq-confirm-ok'));
    await tester.tap(ok);
    await tester.tap(ok, warnIfMissed: false);
    await tester.pump();
    expect(api.thinqCommands, hasLength(1));
    reply.complete(const KioskJobAccepted(jobId: 'job-thinq'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(KioskExecutingView), findsOneWidget);
    expect(api.thinqCommands, hasLength(1));
    await _close(tester);
  });

  group('API', () {
    Future<(KioskJobAccepted, List<http.Request>)> send(List<http.Response> replies) async {
      final seen = <http.Request>[];
      final accepted = await http.runWithClient(
          () => KioskApiService(baseUrl: 'http://hub.test')
              .thinqCommand('air_purifier', 'set_power', {'power': 'POWER_ON'}, clientRequestId: 'kiosk-1'),
          () => MockClient((req) async {
                seen.add(req);
                return replies[seen.length - 1];
              }));
      return (accepted, seen);
    }

    test('요청 번호를 본문에 싣는다', () async {
      final (accepted, seen) = await send([http.Response('{"job_id":"j-1"}', 200)]);
      expect(accepted.jobId, 'j-1');
      expect(jsonDecode(seen.single.body)['client_request_id'], 'kiosk-1');
    });

    test('옛 본체가 모르는 필드라고 거절하면(422) 번호 없이 한 번 다시 보낸다', () async {
      final refused = http.Response(
          jsonEncode({
            'detail': [
              {'type': 'extra_forbidden', 'loc': ['body', 'client_request_id'], 'msg': 'Extra inputs are not permitted'}
            ]
          }),
          422);
      final (accepted, seen) = await send([refused, http.Response('{"job_id":"j-2"}', 200)]);
      expect(accepted.jobId, 'j-2');
      expect(seen, hasLength(2));
      expect((jsonDecode(seen.last.body) as Map).containsKey('client_request_id'), isFalse);
    });

    test('다른 422(값이 틀림)는 다시 보내지 않고 그대로 거절', () async {
      final seen = <http.Request>[];
      await expectLater(
          http.runWithClient(
              () => KioskApiService(baseUrl: 'http://hub.test')
                  .thinqCommand('air_purifier', 'set_power', {'power': 'X'}, clientRequestId: 'kiosk-1'),
              () => MockClient((req) async {
                    seen.add(req);
                    return http.Response.bytes(utf8.encode(jsonEncode({'detail': '지원하지 않는 값이에요'})), 422);
                  })),
          throwsA(isA<KioskApiException>()));
      expect(seen, hasLength(1));
    });
  });
}
