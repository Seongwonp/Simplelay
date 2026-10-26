// 자동 실행 되돌리기(2026-10-26, 맡기기 신뢰 강화) — 알아서 한 일의 결과 줄에 5분 동안 '되돌리기'.
//
// - 본체가 잰 남은 시간(`undo_remaining_s`) 동안만 단추가 보이고, 지나면 저절로 사라진다.
// - 누르면 POST /routines/auto-runs/{run_id}/undo를 한 번 부르고, 본체 문장을 같은 줄에 보인다.
// - 되돌릴 수 없는 결과(남은 시간 없음·옛 본체)에는 단추가 없다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/auto_run.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/auto_run_notice.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_timings.dart';

import 'kiosk_phase_test.dart' show FakeKioskApi, FakeTts, FakeEventStream;

final _undo = find.byKey(const ValueKey('auto-run-undo'));
final _notice = find.byKey(const ValueKey('auto-run-notice'));

KioskAutoRun _run(String jobId, {int? undoSeconds = 300}) => KioskAutoRun.fromJson({
      'job_id': jobId,
      'outcome': 'sent',
      'status': 'succeeded',
      'receipt': 'accepted',
      'confirmation': 'state_confirmed',
      'execution_mode': 'real',
      'target_name': '공기청정기',
      'value_phrase': '켜짐',
      'run_id': undoSeconds == null ? null : jobId,
      'undo_remaining_s': undoSeconds,
    })!;

void _viewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<FakeKioskApi> _start(WidgetTester tester) async {
  _viewport(tester);
  final api = FakeKioskApi();
  await tester.pumpWidget(MaterialApp(home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream())));
  await tester.pump();
  await tester.pump();
  return api;
}

Future<void> _arrive(WidgetTester tester, FakeKioskApi api, KioskAutoRun run) async {
  api.statusResult = KioskStatus(
      running: false, lastJobId: run.jobId, lastStatus: 'succeeded', lastOutcome: 'success', lastRoute: 'thinq',
      lastAutoRun: run);
  await tester.pump(const Duration(seconds: 2));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
}

void main() {
  test('본체 남은 시간을 읽는다 — 없거나 0이면 되돌릴 수 없다', () {
    expect(_run('a').canUndo, isTrue);
    expect(_run('a').undoRemaining, const Duration(seconds: 300));
    expect(_run('b', undoSeconds: null).canUndo, isFalse);
    expect(_run('c', undoSeconds: 0).canUndo, isFalse);
  });

  testWidgets('결과 줄의 되돌리기는 5분 안에만 보이고, 지나면 줄과 함께 사라진다', (tester) async {
    final api = await _start(tester);
    await _arrive(tester, api, _run('auto-1'));
    expect(_notice, findsOneWidget);
    expect(_undo, findsOneWidget);
    expect(find.text(KioskAutoRunNotice.kUndoLabel), findsOneWidget);
    // 보통 알림 시간(12초)이 지나도 되돌릴 수 있는 동안은 남는다.
    await tester.pump(KioskTimings.autoRunNotice + const Duration(seconds: 1));
    expect(_undo, findsOneWidget);
    await tester.pump(const Duration(minutes: 4, seconds: 40)); // 도착 뒤 4분 53초
    expect(_undo, findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(_undo, findsNothing);
    expect(_notice, findsNothing);
    expect(api.undoCalls, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('되돌리기를 누르면 본체에 한 번 보내고 본체 문장을 보인다', (tester) async {
    final api = await _start(tester);
    await _arrive(tester, api, _run('auto-2'));
    await tester.tap(_undo);
    await tester.pump();
    await tester.pump();
    expect(api.undoCalls, ['auto-2']);
    expect(find.text('되돌리고, 이 일은 다시 물어볼게요.'), findsOneWidget);
    expect(_undo, findsNothing);
    await tester.pump(KioskTimings.autoRunNotice);
    await tester.pump();
    expect(_notice, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('5분이 지나 본체가 거절(409)하면 그 이유를 보인다', (tester) async {
    final api = await _start(tester);
    api.undoError = KioskApiException(409, '되돌릴 수 있는 5분이 지났어요.');
    await _arrive(tester, api, _run('auto-3', undoSeconds: 3));
    await tester.tap(_undo);
    await tester.pump();
    await tester.pump();
    expect(api.undoCalls, ['auto-3']);
    expect(find.text('되돌릴 수 있는 5분이 지났어요.'), findsOneWidget);
    await tester.pump(KioskTimings.autoRunNotice);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('되돌릴 수 없는 결과에는 단추가 없다', (tester) async {
    final api = await _start(tester);
    await _arrive(tester, api, _run('auto-4', undoSeconds: null));
    expect(_notice, findsOneWidget);
    expect(_undo, findsNothing);
    await tester.pump(KioskTimings.autoRunNotice);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
