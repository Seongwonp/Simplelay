// 검토 10/19(core5 4): 폰은 자기 실행의 결과를 GET /jobs/{job_id}로 본다 — /status의 마지막 결과 한 칸은 그 사이 다른 실행
// (키오스크·자동 실행)이 끝나면 덮여, 끝난 내 실행을 '모름'으로 보였다. 옛 본체(경로 없음)는 종전처럼 /status.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/services/rpi_api_service.dart';

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)), status,
    headers: {'content-type': 'application/json; charset=utf-8'});

/// 다른 실행(job-2)이 내 실행 뒤에 끝난 /status.
Map<String, dynamic> _statusAfterOther() => {
      'running': false,
      'last_job_id': 'job-2',
      'last_status': 'failed',
      'last_outcome': 'failed',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer track(RpiApiService api) {
    final c = ProviderContainer(overrides: [rpiApiServiceProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    c.read(executionStatusProvider.notifier).beginHttpJob(api: api, jobId: 'job-1', label: '켜기');
    return c;
  }

  test('그 사이 다른 실행이 끝나 /status가 덮여도 내 실행의 결과를 받는다', () async {
    final paths = <String>[];
    final api = RpiApiService('http://rpi5.local:8000', client: MockClient((r) async {
      paths.add(r.url.path);
      if (r.url.path == '/jobs/job-1') {
        return _json({
          'running': false,
          'finished': true,
          'step': null,
          'job_id': null,
          'last_job_id': 'job-1',
          'last_status': 'succeeded',
          'last_outcome': 'success',
          'last_execution_mode': 'mock',
          'last_stop_level': null,
          'last_stop_ack_ms': null,
          'last_stop_job_id': null,
        });
      }
      if (r.url.path == '/status') return _json(_statusAfterOther());
      return _json({'detail': 'Not Found'}, 404);
    }));
    final c = track(api);
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    final s = c.read(executionStatusProvider);
    expect(s.phase, ExecutionPhase.completed, reason: 'job-2의 실패를 싣지 않고 job-1의 성공');
    expect(s.outcome, 'success');
    expect(paths, contains('/jobs/job-1'));
  });

  test('실행 중이면 그 실행의 진행을 본다', () async {
    final api = RpiApiService('http://rpi5.local:8000', client: MockClient((r) async {
      if (r.url.path == '/jobs/job-1') {
        return _json({'running': true, 'finished': false, 'job_id': 'job-1', 'completed_steps': 1, 'total_steps': 3});
      }
      return _json({'running': true, 'job_id': 'job-other'});
    }));
    final c = track(api);
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    final s = c.read(executionStatusProvider);
    expect(s.phase, ExecutionPhase.running);
    expect(s.completedSteps, 1);
    expect(s.totalSteps, 3);
  });

  test('본체가 그 실행을 모르면(새 본체 404) /status로 추정하지 않는다', () async {
    final paths = <String>[];
    final api = RpiApiService('http://rpi5.local:8000', client: MockClient((r) async {
      paths.add(r.url.path);
      if (r.url.path == '/jobs/job-1') return _json({'detail': 'job not found'}, 404);
      return _json({'running': false, 'last_job_id': 'job-1', 'last_outcome': 'success', 'last_status': 'succeeded'});
    }));
    final c = track(api);
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(c.read(executionStatusProvider).phase, ExecutionPhase.running, reason: '흔적 없음 — 몇 번 기다린 뒤 모름');
    expect(paths.where((p) => p == '/status'), isEmpty);
  });

  test('옛 본체(경로 없음)는 /status의 last_job_id로 판정하고 다시 묻지 않는다', () async {
    final paths = <String>[];
    var polls = 0;
    final api = RpiApiService('http://rpi5.local:8000', client: MockClient((r) async {
      paths.add(r.url.path);
      if (r.url.path.startsWith('/jobs/')) return _json({'detail': 'Not Found'}, 404);
      polls++;
      return polls < 2
          ? _json({'running': true, 'job_id': 'job-1'})
          : _json({'running': false, 'last_job_id': 'job-1', 'last_outcome': 'success', 'last_status': 'succeeded'});
    }));
    final c = track(api);
    await Future<void>.delayed(const Duration(milliseconds: 2300));
    expect(c.read(executionStatusProvider).phase, ExecutionPhase.completed);
    expect(paths.where((p) => p.startsWith('/jobs/')).length, 1, reason: '없는 경로는 한 번만 묻는다');
  });
}
