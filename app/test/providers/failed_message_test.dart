// 실패한 실행의 결과 문장(외부 평가 2026-10-13 M4).
//
// 실패(outcome=failed)라는 것만으로는 실행이 시작되지 않았는지 알 수 없다 — 접수된 뒤 일부 버튼을 누르고
// 실패했을 수도 있다. 미전송 근거(receipt=not_dispatched)가 있을 때만 "보내지 못했어요"+다시 시도를 말하고,
// 접수됨·부분 실행·원인 불명은 기록 화면(display_status.dart)과 같은 근거 수준으로 낮추며 다시 시도를 권하지 않는다.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/command_result.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/tts_provider.dart';
import 'package:simplelay/services/app_tts_service.dart';
import 'package:simplelay/services/rpi_api_service.dart';

class _QuietTts extends AppTtsService {
  @override
  Future<void> speak(String text) async {}
}

const _notSent = '누름 장치에 보내지 못했어요. 연결을 보고 다시 해 주세요.';
const _partial = '끝까지 하지 못했어요. 집에서 가전을 확인해야 해요.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('finishedMessage(failed)', () {
    test('물리: 미전송 근거가 있을 때만 보내지 못했다고 하고 다시 시도를 권한다', () {
      expect(
          finishedMessage(
              kind: ResultKind.failed, route: 'physical', receipt: 'not_dispatched'),
          _notSent);
    });

    for (final receipt in ['accepted', 'unknown', null]) {
      test('물리: 접수됨·원인 불명($receipt)은 시작하지 못했다고 단정하지 않고 다시 시도를 권하지 않는다', () {
        final m = finishedMessage(
            kind: ResultKind.failed, route: 'physical', receipt: receipt);
        expect(m, _partial);
        expect(m, isNot(contains('시작하지 못했')));
        expect(m, isNot(matches('다시 (해|시도|하기)')));
      });
    }

    test('ThinQ: 보내지 않았으면 다시 시도, 접수 뒤 실패면 가전 확인만', () {
      expect(
          finishedMessage(
              kind: ResultKind.failed, route: 'thinq', receipt: 'not_dispatched'),
          '가전에 보내지 못했어요. 연결을 보고 다시 해 주세요.');
      final accepted = finishedMessage(
          kind: ResultKind.failed, route: 'thinq', receipt: 'accepted');
      expect(accepted, '가전이 하지 않았어요. 가전 상세에서 지금 상태를 볼 수 있어요.');
      expect(accepted, isNot(matches('다시 (해|시도|하기)')));
    });
  });

  test('실행 상태 화면: 접수되어 일부 버튼을 누른 뒤 실패한 실행은 재시도를 권하지 않는다(실제 배선)', () async {
    final c = ProviderContainer(
        overrides: [ttsServiceProvider.overrideWithValue(_QuietTts())]);
    addTearDown(c.dispose);
    final api = RpiApiService('http://rpi5.local:8000',
        client: MockClient((request) async => http.Response.bytes(
            utf8.encode(jsonEncode({
              'running': false,
              'job_id': null,
              'last_job_id': 'J1',
              'last_status': 'failed',
              'last_outcome': 'failed',
              'last_route': 'physical',
              'last_receipt': 'accepted',
              'last_execution_mode': 'real',
              'last_buttons': [
                {'button': '즉석밥', 'success': true},
                {'button': '시작', 'success': false},
              ],
            })),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'})));
    c.read(executionStatusProvider.notifier)
        .beginHttpJob(api: api, jobId: 'J1', label: '즉석밥 데우기');
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (c.read(executionStatusProvider).phase == ExecutionPhase.running) {
      if (DateTime.now().isAfter(end)) fail('끝나지 않았다');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final s = c.read(executionStatusProvider);
    expect(s.phase, ExecutionPhase.failed);
    expect(s.message, _partial);
  });
}
