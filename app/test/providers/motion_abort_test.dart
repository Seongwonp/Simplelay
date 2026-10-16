// 모션 걸림(stall) 알람을 '눌림 확인 실패'로 보이지 않는다(2026-10-14, 보드 날 발견 2).
// 서버 /status `last_abort_reason`·/history `abort_reason` → "모터가 걸려 멈췄어요" 계열 문장, 다시 시도 권하지 않음.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/command_result.dart';
import 'package:simplelay/models/display_status.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/tts_provider.dart';
import 'package:simplelay/screens/status_screen.dart';
import 'package:simplelay/services/app_tts_service.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

class _FakeTts extends AppTtsService {
  final spoken = <String>[];
  @override
  Future<void> speak(String text) async => spoken.add(text);
}

Future<(ExecutionStatus, List<String>)> _finish(Map<String, dynamic> body) async {
  final tts = _FakeTts();
  final container = ProviderContainer(overrides: [ttsServiceProvider.overrideWithValue(tts)]);
  addTearDown(container.dispose);
  final api = RpiApiService(
    'http://rpi5.local:8000',
    client: MockClient((request) async => http.Response.bytes(
          utf8.encode(jsonEncode({'running': false, 'last_job_id': 'J1', ...body})),
          200,
          headers: {'content-type': 'application/json'},
        )),
  );
  container.read(executionStatusProvider.notifier).beginHttpJob(api: api, jobId: 'J1', label: '즉석밥 데워줘');
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  return (container.read(executionStatusProvider), tts.spoken);
}

RpiHistoryEntry _entry(Map<String, dynamic> extra) => RpiHistoryEntry.fromJson({
      'job_id': 'j',
      'finished_at': '2026-10-14T08:00:00+09:00',
      'status': 'safety_stopped',
      'retry_count': 0,
      'buttons': const [
        {'button': '즉석밥', 'success': false, 'attempts': 1},
      ],
      ...extra,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('원인 코드 → 문장', () {
    expect(motionAbortSentence('motion_alarm: stall'), '모터가 걸려 멈췄어요');
    expect(motionAbortSentence('motion_alarm: limit'), '모터 보드가 이상을 알려 멈췄어요');
    expect(motionAbortSentence('motion_reset'), '모터 보드가 다시 켜져 멈췄어요');
    expect(motionAbortSentence('motion_timeout'), '모터 보드가 제때 답하지 않아 멈췄어요');
    expect(motionAbortSentence('motion_not_ready'), '누름 장치가 준비되지 않아 멈췄어요');
    expect(motionAbortSentence('motion_link_error'), '누름 장치 연결이 끊겨 멈췄어요');
    expect(motionAbortSentence('motion_future_thing'), '누름 장치가 멈췄어요');
    expect(motionAbortSentence(null), isNull);
    expect(motionAbortSentence('stall'), isNull);
  });

  test('실행 상태: 걸림 알람은 눌림 확인 실패가 아니라 걸려 멈춤으로 말한다', () async {
    final (s, spoken) = await _finish({
      'last_status': 'safety_stopped',
      'last_outcome': 'safety_stop',
      'last_route': 'physical',
      'last_execution_mode': 'real',
      'last_retry_count': 0,
      'last_abort_reason': 'motion_alarm: stall',
    });
    expect(s.phase, ExecutionPhase.failed);
    expect(s.abortReason, 'motion_alarm: stall');
    expect(s.message, '모터가 걸려 멈췄어요. 다시 누르지 않았어요. 가전과 누름 장치를 직접 봐 주세요.');
    expect(s.message, isNot(contains('눌림을 확인하지 못해')));
    expect(spoken.single, s.message);
  });

  test('원인이 없는 안전 정지는 종전 문장', () async {
    final (s, _) = await _finish({
      'last_status': 'safety_stopped',
      'last_outcome': 'safety_stop',
      'last_route': 'physical',
      'last_execution_mode': 'real',
    });
    expect(s.message, '눌림을 확인하지 못해 멈췄어요. 가전을 먼저 봐 주세요. 가전이 이미 움직이고 있으면 다시 시도하지 마세요. 같은 버튼을 또 누르게 돼요.');
  });

  test('기록: 걸림 원인이 있으면 "다시 눌러도 확인하지 못해"라고 하지 않는다', () {
    final r = historyResult(_entry(const {
      'outcome': 'safety_stop',
      'termination': 'motion_aborted',
      'abort_reason': 'motion_alarm: stall',
    }));
    expect(r.sentence, '모터가 걸려 멈췄어요');
    expect(r.next, '다시 누르지 않았어요 · 장치를 확인해 주세요');
    final old = historyResult(_entry(const {'outcome': 'safety_stop', 'termination': 'retries_exhausted'}));
    expect(old.sentence, '다시 눌러도 확인하지 못해 안전 정지');
  });

  testWidgets('결과 화면: 걸림이면 다시 시도를 권하지 않는다(자동 재누름·재시도 버튼 없음)', (tester) async {
    await tester.pumpWidget(buildScreen(const StatusScreen(),
        executionStatus: ExecutionStatus(
          phase: ExecutionPhase.failed,
          outcome: 'safety_stop',
          route: 'physical',
          abortReason: 'motion_alarm: stall',
          message: finishedMessage(kind: ResultKind.safetyStop, abortReason: 'motion_alarm: stall'),
        )));
    expect(findPlainText('모터가 걸려 멈췄어요', contains: true), findsWidgets);
    expect(find.text('다시 시도'), findsNothing);
    expect(find.textContaining('다시 실행해 주세요'), findsNothing);
    expect(find.widgetWithText(FilledButton, '확인'), findsOneWidget);
  });

  testWidgets('결과 화면: 원인 없는 안전 정지는 종전대로 다시 시도', (tester) async {
    await tester.pumpWidget(buildScreen(const StatusScreen(),
        executionStatus: const ExecutionStatus(phase: ExecutionPhase.failed, outcome: 'safety_stop')));
    expect(find.text('다시 시도'), findsOneWidget);
  });
}
