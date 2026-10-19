// 사람이 '확인함'을 본체에 적는다(사용자 보고 버그 2026-10-19) — 옛 코드에서 실패하는 것을 확인한 시험.
//
// 원인: 키오스크의 지난 일 '확인'·'움직였어요/안 움직였어요' 답은 키오스크 메모리에만 남았다 — 폰은 여전히 못 한 일이었고,
// 가전 칸 '!'(마지막 실행 실패)는 다음 실행 때까지 남았다. 폰에서 '기록 보기'로 확인해도 키오스크는 몰랐다.
// 이제: 확인·답은 본체 POST /acks에 적고, 키오스크는 GET /acks(10초마다)로 다른 기기에서 확인한 것도 내린다. 새 실패는 다시 뜬다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';

import 'kiosk_phase_test.dart' show FakeKioskApi, FakeTts, FakeEventStream;

final _microwave = applianceFromServerJson({
  'id': 'microwave',
  'name': '전자레인지',
  'category': 'microwave',
  'rows': 1,
  'cols': 2,
  'buttons': [
    {'id': 'BT-1', 'label': '즉석밥', 'x': 0, 'y': 0},
    {'id': 'BT-2', 'label': '시작', 'x': 1, 'y': 0},
  ],
  'can_execute': true,
  'readiness': 'operable',
});

KioskStatus _failed(String jobId) => KioskStatus(
    running: false,
    lastJobId: jobId,
    lastApplianceId: 'microwave',
    lastOutcome: 'failed',
    lastStatus: 'failed',
    lastExecutionMode: 'real');

Future<FakeKioskApi> _start(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final api = FakeKioskApi()
    ..applianceList = [_microwave]
    ..statusResult = const KioskStatus(running: false, lastJobId: 'job-0', lastOutcome: 'success');
  await tester.pumpWidget(MaterialApp(home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream())));
  await tester.pump();
  await tester.pump();
  return api;
}

/// 새 실패 결과를 받고 결과 화면을 닫아 처음 화면으로.
Future<void> _failAndClose(WidgetTester tester, FakeKioskApi api, String jobId) async {
  api.statusResult = _failed(jobId);
  await tester.pump(const Duration(seconds: 2));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
  expect(find.byType(KioskDoneView), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('done-home')));
  await tester.pump();
  await tester.pump(const Duration(seconds: 2)); // 상태 조회 — 가전 칸 표시
  await tester.pump();
}

final _past = find.byKey(const ValueKey('idle-past-result'));
final _mark = find.byKey(const ValueKey('tile-mark-microwave'));

void main() {
  testWidgets("지난 일 '확인'은 본체에 적고 가전 칸 '!'도 내린다", (tester) async {
    final api = await _start(tester);
    await _failAndClose(tester, api, 'job-2');
    expect(_past, findsOneWidget);
    expect(_mark, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('idle-past-result-ok')));
    await tester.pump();
    expect(api.ackPosts, [('job-2', 'seen')]);
    expect(_past, findsNothing);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(_mark, findsNothing, reason: '확인한 실패의 표시는 다음 실행을 기다리지 않고 내린다');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets("다른 기기(폰 '기록 보기')에서 확인하면 키오스크 지난 일·표시도 사라진다 — 새 실패는 다시 뜬다", (tester) async {
    final api = await _start(tester);
    await _failAndClose(tester, api, 'job-2');
    expect(_past, findsOneWidget);
    api.ackedJobsResult = {'job-2': 'seen'}; // 폰이 본체에 적었다
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(_past, findsNothing);
    expect(_mark, findsNothing);
    expect(api.ackPosts, isEmpty, reason: '키오스크가 따로 적지 않는다');

    await _failAndClose(tester, api, 'job-3');
    expect(_past, findsOneWidget);
    expect(_mark, findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('옛 본체(/acks 없음)면 지난 일은 그대로 — 확인을 지어내지 않는다', (tester) async {
    final api = await _start(tester);
    api.ackedJobsResult = null;
    await _failAndClose(tester, api, 'job-2');
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(_past, findsOneWidget);
    expect(_mark, findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // 검토 10/19(/acks 계약 — 사람이 본 것만): 키오스크는 보호자 알림 목록을 보이지 않는다. 지난 일 '확인'은 그 실행 하나만
  // (job_id + answer) 적고, 실행 번호를 모르는 지난 일(접수 전에 끊긴 실행)은 아무것도 적지 않는다 — 예전에는 맨
  // failures_seen:true를 보내 본체의 못 한 일·최근 실행 기록 전체를 '봤다'로 올렸다(아무도 안 본 실패까지 폰에서 사라졌다).
  testWidgets("실행 번호를 모르는 지난 일 '확인'은 본체에 아무것도 적지 않는다", (tester) async {
    final api = await _start(tester);
    api
      ..suggestionList = [
        const KioskSuggestion(id: 's1', purpose: '즉석밥 데워줘', occurrences: 3, applianceId: 'microwave'),
      ]
      ..executeError = Exception('server down');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    api.suggestionList = [];
    await tester.tap(find.byKey(const ValueKey('suggestion-approve')));
    await tester.pump(); // 접수 실패 — 실행 번호 없음
    await tester.pump();
    expect(find.byType(KioskDoneView), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('done-home')));
    await tester.pump();
    expect(_past, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('idle-past-result-ok')));
    await tester.pump();
    expect(_past, findsNothing, reason: '화면에서는 닫는다');
    expect(api.ackPosts, isEmpty, reason: "본체에 댈 번호가 없다 — 맨 failures_seen으로 못 한 일 전체를 '봤다'로 올리지 않는다");
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
