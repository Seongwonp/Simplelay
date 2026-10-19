// 검토 10/19(코어 4차 #11) — 지난 일 '확인'을 본체가 적지 못하면(POST 실패, 본체 목록에도 없음) 지운 지난 일 줄을 되살린다.
// 예전에는 화면이 먼저 지운 줄을 되살릴 길이 없어 키오스크만 '확인함'이고 폰은 못 한 일로 남았다. 옛 본체(/acks 없음)면 종전처럼 화면에서만 닫는다.
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

KioskStatus _ended(String jobId, {String outcome = 'stopped', String status = 'safety_stopped'}) => KioskStatus(
    running: false,
    lastJobId: jobId,
    lastApplianceId: 'microwave',
    lastOutcome: outcome,
    lastStatus: status,
    lastExecutionMode: 'real');

Future<FakeKioskApi> _pumpKiosk(WidgetTester tester, {required FakeKioskApi fake}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final api = fake
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

void main() {
  group('11. 지난 일 확인을 본체가 적지 못하면 되살린다', () {
    testWidgets('POST /acks가 실패하고 본체 목록에도 없으면 지난 일 줄이 다시 보인다', (tester) async {
      final api = await _pumpKiosk(tester, fake: _FailAckApi());
      api.statusResult = _ended('job-2', outcome: 'failed', status: 'failed');
      await _poll(tester);
      await tester.pump(const Duration(milliseconds: 900));
      expect(find.byType(KioskDoneView), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('done-home')));
      await tester.pump();
      final past = find.byKey(const ValueKey('idle-past-result'));
      expect(past, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('idle-past-result-ok')));
      await tester.pump();
      await tester.pump();
      expect(api.ackPosts, [('job-2', 'seen')]);
      expect(past, findsOneWidget, reason: '본체에 적히지 않은 확인을 화면만 지어내지 않는다');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('옛 본체(/acks 없음)면 종전처럼 화면에서만 닫는다', (tester) async {
      final fake = _FailAckApi()..ackedJobsResult = null;
      final api = await _pumpKiosk(tester, fake: fake);
      api.ackedJobsResult = null;
      api.statusResult = _ended('job-2', outcome: 'failed', status: 'failed');
      await _poll(tester);
      await tester.pump(const Duration(milliseconds: 900));
      await tester.tap(find.byKey(const ValueKey('done-home')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('idle-past-result-ok')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('idle-past-result')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}

/// POST /acks가 늘 실패하는 본체 — 목록에도 넣지 않는다.
class _FailAckApi extends FakeKioskApi {
  @override
  Future<bool> postAck({required String jobId, String answer = 'seen'}) async {
    ackPosts.add((jobId, answer));
    return false;
  }
}
