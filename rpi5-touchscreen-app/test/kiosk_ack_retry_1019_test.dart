// 검토 10/19(코어 5차 #9) — 키오스크의 '확인'·'움직였어요/안 움직였어요' 답은 본체가 적을 때까지 지키고 다시 보낸다.
//
// 예전: POST /acks가 한 번 실패하면 답을 버렸다 — 끊긴 동안 답한 확인은 본체에 끝내 남지 않아, 연결이 돌아오면 가전 칸 '!'과
// 폰의 못 한 일 경고가 다시 떴다(본체에 닿는데 못 적은 경우는 지난 일 줄만 되살리고 끝났다).
// 이제: 답은 POST가 성공하거나 본체 목록(GET /acks)에 같은 답이 보일 때까지 대기에 남고, 본체 목록을 다시 읽을 수 있을 때마다 다시 보낸다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

final _microwave = applianceFromServerJson({
  'id': 'microwave',
  'name': '전자레인지',
  'category': 'microwave',
  'rows': 1,
  'cols': 2,
  'buttons': [
    {'id': 'BT-1', 'label': '해동', 'x': 0, 'y': 0},
    {'id': 'BT-2', 'label': '시작', 'x': 1, 'y': 0},
  ],
  'can_execute': true,
  'readiness': 'operable',
});

const _base = KioskStatus(running: false, lastJobId: 'job-0', lastOutcome: 'success', lastStatus: 'succeeded');

const _failed = KioskStatus(
    running: false,
    lastJobId: 'job-2',
    lastApplianceId: 'microwave',
    lastOutcome: 'failed',
    lastStatus: 'failed',
    lastExecutionMode: 'real');

/// 확인 기록이 끊겼다 돌아오는 본체. [reachable]이 거짓이면 GET /acks도 못 읽고, [stores]가 거짓이면 POST /acks가 적지 못한다.
class _FlakyAckApi extends FakeKioskApi {
  bool reachable = true;
  bool stores = true;

  @override
  Future<Map<String, String>?> ackedJobs() async => reachable ? ackedJobsResult : null;

  @override
  Future<bool> postAck({required String jobId, String answer = 'seen'}) async {
    ackPosts.add((jobId, answer));
    if (!reachable || !stores) return false;
    ackedJobsResult = {...?ackedJobsResult, jobId: answer};
    return true;
  }
}

Future<_FlakyAckApi> _pumpKiosk(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final api = _FlakyAckApi()
    ..applianceList = [_microwave]
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

/// 실패 결과를 받고 결과 화면을 닫아 처음 화면 '지난 일' 줄까지.
Future<void> _failAndClose(WidgetTester tester, FakeKioskApi api) async {
  api.statusResult = _failed;
  await _poll(tester);
  await tester.pump(const Duration(milliseconds: 900));
  expect(find.byType(KioskDoneView), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('done-home')));
  await tester.pump();
  expect(_past, findsOneWidget);
}

/// 본체 목록 조회 주기(10초)를 지난다.
Future<void> _waitAckFetch(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await _poll(tester);
  }
}

final _past = find.byKey(const ValueKey('idle-past-result'));
final _mark = find.byKey(const ValueKey('tile-mark-microwave'));

void main() {
  testWidgets('끊긴 동안 누른 확인은 연결이 돌아오면 다시 보내 본체에 적고, 가전 칸 표시도 다시 뜨지 않는다', (tester) async {
    final api = await _pumpKiosk(tester);
    await _failAndClose(tester, api);
    api.reachable = false;
    await tester.tap(find.byKey(const ValueKey('idle-past-result-ok')));
    await tester.pump();
    await tester.pump();
    expect(api.ackPosts, [('job-2', 'seen')]);
    expect(_past, findsNothing);

    api.reachable = true;
    await _waitAckFetch(tester);
    expect(api.ackPosts, [('job-2', 'seen'), ('job-2', 'seen')], reason: '연결이 돌아오면 다시 보낸다');
    expect(api.ackedJobsResult, containsPair('job-2', 'seen'));
    expect(_past, findsNothing);
    expect(_mark, findsNothing, reason: '본체가 적은 확인 — 가전 칸 표시가 다시 뜨지 않는다');

    await _waitAckFetch(tester);
    expect(api.ackPosts, hasLength(2), reason: '적은 뒤에는 더 보내지 않는다');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('본체에 닿는데 못 적었으면 지난 일 줄을 되살리고, 다시 보내 적으면 줄을 내린다', (tester) async {
    final api = await _pumpKiosk(tester);
    await _failAndClose(tester, api);
    api.stores = false;
    await tester.tap(find.byKey(const ValueKey('idle-past-result-ok')));
    await tester.pump();
    await tester.pump();
    expect(_past, findsOneWidget, reason: '본체에 적히지 않은 확인을 화면만 지어내지 않는다(코어 4차 #11)');

    api.stores = true;
    await _waitAckFetch(tester);
    expect(api.ackPosts.length, greaterThanOrEqualTo(2));
    expect(api.ackedJobsResult, containsPair('job-2', 'seen'));
    expect(_past, findsNothing, reason: '다시 보내 적었다');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
