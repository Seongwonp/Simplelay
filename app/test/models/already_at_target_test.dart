// ThinQ 결과를 확인한 사실만큼(2026-10-14 보드 날 발견 3) — 네 경우:
// - 이미 목표값(보내지 않음, already_at_target): "이미 강풍으로 설정돼 있어요. 변경 명령을 보내지 않았어요."
// - 바꿈(state_confirmed): "강풍으로 바꿨어요."
// - 보낸 뒤 목표값·전 값 모름(state_confirmed_unknown_before): "강풍으로 설정된 것을 확인했어요." ('바꿨어요' 금지)
// - 미확인(unconfirmed): "…설정이 바뀌었는지 확인하지 못했어요…"
//
// 실행 상태·기록·단계 줄이 이미 목표값을 실패·미확인으로도, '바꿨어요'·'보냈어요'로도 말하지 않고, 모의는 모의라고 밝힌다.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/command_result.dart';
import 'package:simplelay/models/display_status.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/models/scenario_run.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/tts_provider.dart';
import 'package:simplelay/services/app_tts_service.dart';
import 'package:simplelay/services/rpi_api_service.dart';

class _QuietTts extends AppTtsService {
  @override
  Future<void> speak(String text) async {}
}

const _already = '이미 강풍으로 설정돼 있어요. 변경 명령을 보내지 않았어요.';
const _changed = '강풍으로 바꿨어요.';
const _seen = '강풍으로 설정된 것을 확인했어요.';

void _notChangedOrFailed(String text) {
  expect(text, isNot(contains('바꿨')));
  expect(text, isNot(contains('보냈')));
  expect(text, isNot(contains('확인하지 못했')));
  expect(text, isNot(contains('못 했어요')));
  expect(text, isNot(matches('다시 (해|시도|하기)')));
}

RpiHistoryEntry _entry(String mode, {String confirmation = 'already_at_target',
        String receipt = 'not_dispatched', String detail = _already}) =>
    RpiHistoryEntry.fromJson({
      'job_id': 'j',
      'finished_at': '2026-10-14T08:00:00+09:00',
      'status': 'succeeded',
      'outcome': 'success',
      'retry_count': 0,
      'buttons': const [],
      'route': 'thinq',
      'receipt': receipt,
      'confirmation': confirmation,
      'execution_mode': mode,
      'detail': detail,
    });

String _finished(String confirmation, String mode, {String? detail, String receipt = 'accepted'}) =>
    finishedMessage(
        kind: ResultKind.success,
        executionMode: mode,
        route: 'thinq',
        receipt: receipt,
        confirmation: confirmation,
        detail: detail);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('확인 수준 칩: 이미 그 설정 · 설정된 것 확인(모의는 모의라고)', () {
    String? label(String c, String mode) => confirmationLabel(
        route: 'thinq',
        receipt: c == 'already_at_target' ? 'not_dispatched' : 'accepted',
        confirmation: c,
        kind: ResultKind.success,
        executionMode: mode);
    expect(label('already_at_target', 'real'), '이미 그 설정이라 보내지 않았어요');
    expect(label('already_at_target', 'mock'), '연습이에요. 이미 그 설정이었어요');
    expect(label('state_confirmed_unknown_before', 'real'), '그 설정인 것을 확인했어요');
    expect(label('state_confirmed_unknown_before', 'mock'), '연습이에요. 그 설정인 것을 봤어요');
    expect(label('state_confirmed', 'real'), '상태를 확인했어요');
  });

  test('결과 문장 네 경우: 서버 문장(그 실행의 설정 이름) 그대로', () {
    final already = _finished('already_at_target', 'real', detail: _already, receipt: 'not_dispatched');
    expect(already, _already);
    _notChangedOrFailed(already);
    expect(_finished('state_confirmed', 'real', detail: _changed), _changed);
    final seen = _finished('state_confirmed_unknown_before', 'real', detail: _seen);
    expect(seen, _seen);
    expect(seen, isNot(contains('바꿨')));
    expect(
        finishedMessage(kind: ResultKind.unconfirmed, route: 'thinq', receipt: 'accepted'),
        '보냈지만 설정이 바뀌었는지 몰라요. 집에서 가전을 확인해야 해요.');
    // 서버 문장이 없으면(옛 서버) 일반 문장 — 바꿨다고 지어내지 않는다.
    expect(_finished('already_at_target', 'real', receipt: 'not_dispatched'),
        '이미 그 설정이라 보내지 않았어요.');
    expect(_finished('state_confirmed_unknown_before', 'real'), '원하는 설정인 것을 확인했어요.');
  });

  test('모의 결과는 모의 표시를 유지한다', () {
    final already = _finished('already_at_target', 'mock', detail: _already, receipt: 'not_dispatched');
    expect(already, '연습이에요. $_already 실제 가전은 그대로예요.');
    _notChangedOrFailed(already);
    final seen = _finished('state_confirmed_unknown_before', 'mock', detail: _seen);
    expect(seen, startsWith('연습이에요. '));
    expect(seen, contains('실제 가전은 그대로예요'));
    expect(_finished('state_confirmed', 'mock', detail: _changed),
        '연습으로 보내고 연습 상태를 봤어요. 실제 가전은 그대로예요.');
  });

  test('기록: 이미 목표값은 성공으로, 변경 명령을 보내지 않았다고(연결 확인을 권하지 않는다)', () {
    final real = historyResult(_entry('real'), applianceName: '공기청정기');
    expect(real.kind, ResultKind.success);
    expect(real.sentence, '이미 그 설정이라 보내지 않았어요');
    expect(real.next, isNull);
    final mock = historyResult(_entry('mock'), applianceName: '공기청정기(모의)');
    expect(mock.kind, ResultKind.success);
    expect(mock.sentence, '연습이에요. 이미 그 설정이라 보내지 않았어요');
    final changed = historyResult(
        _entry('real', confirmation: 'state_confirmed', receipt: 'accepted', detail: _changed),
        applianceName: '공기청정기');
    expect(changed.sentence, '강풍으로 바꿨어요');
    final seen = historyResult(
        _entry('real', confirmation: 'state_confirmed_unknown_before', receipt: 'accepted', detail: _seen),
        applianceName: '공기청정기');
    expect(seen.sentence, '강풍으로 설정된 것을 확인했어요');
  });

  test('단계 줄: 성공 · 이미 그 설정', () {
    const step = ScenarioRunStep(
        targetId: 'air_purifier',
        route: 'thinq',
        status: 'succeeded',
        receipt: 'not_dispatched',
        confirmation: 'already_at_target',
        executionMode: 'real');
    final facts = runStepFacts(step);
    expect(facts, 'LG 가전, 이미 그 설정이라 보내지 않았어요, 완료');
  });

  test('실행 상태 화면(실제 배선): 완료로, 서버의 이미-목표값 문장 그대로', () async {
    final c = ProviderContainer(
        overrides: [ttsServiceProvider.overrideWithValue(_QuietTts())]);
    addTearDown(c.dispose);
    final api = RpiApiService('http://rpi5.local:8000',
        client: MockClient((request) async => http.Response.bytes(
            utf8.encode(jsonEncode({
              'running': false,
              'job_id': null,
              'last_job_id': 'J1',
              'last_status': 'succeeded',
              'last_outcome': 'success',
              'last_route': 'thinq',
              'last_receipt': 'not_dispatched',
              'last_confirmation': 'already_at_target',
              'last_detail': _already,
              'last_execution_mode': 'real',
            })),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'})));
    c.read(executionStatusProvider.notifier)
        .beginHttpJob(api: api, jobId: 'J1', label: '공기청정기 강풍');
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (c.read(executionStatusProvider).phase == ExecutionPhase.running) {
      if (DateTime.now().isAfter(end)) fail('끝나지 않았다');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final s = c.read(executionStatusProvider);
    expect(s.phase, ExecutionPhase.completed);
    expect(s.message, _already);
    _notChangedOrFailed(s.message!);
  });
}
