// 검토 10/19: 쉬다가 루틴의 2번째 이후 구간에서 실행을 알아챈 폰(/status의 돌고 있는 실행, 남은 구간 번호)은 그 구간 번호만
// 알아, 구간 하나가 끝나면 루틴이 이어 가는데도 '끝났어요'로 말했다. 새 본체는 /status·GET /jobs/{구간 번호}에 routine_run_id
// (루틴 첫 번호)를 싣는다 — 폰은 그 번호로 갈아타 루틴이 다 끝날 때까지 하는 중으로 보이고 정지는 그 루틴만 멈춘다.
// 옛 본체(필드 없음)는 종전대로 구간 번호를 따라간다.
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

/// 2번째 구간(job-2)의 GET /jobs — 구간은 끝났고 루틴(job-1)은 다음 구간을 기다린다.
Map<String, dynamic> _segmentDone({bool routine = true}) => {
      'running': false,
      'finished': true,
      'job_id': null,
      'last_job_id': 'job-2',
      'last_status': 'succeeded',
      'last_outcome': 'success',
      if (routine) ...{
        'routine_run_id': 'job-1',
        'routine_status': 'running',
        'routine_segment': 2,
        'routine_segment_job_id': 'job-2',
      },
    };

/// 루틴 첫 번호의 GET /jobs — 도는 중(3번째 구간).
Map<String, dynamic> _rootRunning() => {
      'running': true,
      'finished': false,
      'job_id': 'job-1',
      'last_job_id': null,
      'routine_run_id': 'job-1',
      'routine_status': 'running',
      'routine_segment': 3,
      'routine_segment_job_id': 'job-3',
    };

Map<String, dynamic> _rootDone() => {
      'running': false,
      'finished': true,
      'job_id': null,
      'last_job_id': 'job-1',
      'last_status': 'succeeded',
      'last_outcome': 'success',
      'routine_run_id': 'job-1',
      'routine_status': 'succeeded',
      'routine_segment': 3,
      'routine_segment_job_id': 'job-3',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer container(RpiApiService api) {
    final c = ProviderContainer(overrides: [rpiApiServiceProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    return c;
  }

  test('2번째 구간 번호를 따라가면 루틴 첫 번호로 갈아타 루틴이 다 끝날 때까지 하는 중이다', () async {
    final paths = <String>[];
    var rootPolls = 0;
    final api = RpiApiService('http://rpi5.local:8000', client: MockClient((r) async {
      paths.add('${r.method} ${r.url.path}');
      if (r.url.path == '/jobs/job-2') return _json(_segmentDone());
      if (r.url.path == '/jobs/job-1') {
        rootPolls++;
        return _json(rootPolls < 2 ? _rootRunning() : _rootDone());
      }
      if (r.url.path == '/routines/runs/job-1/stop') return _json({'ok': true});
      return _json({'detail': 'unexpected'}, 404);
    }));
    final c = container(api);
    final n = c.read(executionStatusProvider.notifier);
    n.beginHttpJob(api: api, jobId: 'job-2', label: '저녁 루틴');

    await Future<void>.delayed(const Duration(milliseconds: 1300));
    var s = c.read(executionStatusProvider);
    expect(s.phase, ExecutionPhase.running, reason: '구간 하나의 끝은 루틴의 끝이 아니다');
    expect(s.sequenceId, 'job-1');
    expect(s.message, contains('2번째'));

    await Future<void>.delayed(const Duration(milliseconds: 1000));
    s = c.read(executionStatusProvider);
    expect(s.phase, ExecutionPhase.running);
    expect(s.message, contains('3번째'));
    expect(await n.emergencyStop(), isTrue);
    expect(paths, contains('POST /routines/runs/job-1/stop'), reason: '정지는 그 루틴만 멈춘다');
    expect(paths, isNot(contains('POST /stop')));

    await Future<void>.delayed(const Duration(milliseconds: 1000));
    s = c.read(executionStatusProvider);
    expect(s.phase, ExecutionPhase.completed, reason: '루틴 첫 번호가 끝났을 때만 끝난다');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('pending_job_id'), isNull);
  });

  test('보냈는데 답을 모를 때 /status가 구간 사이의 루틴을 알리면 루틴 첫 번호를 따라간다', () async {
    final api = RpiApiService('http://rpi5.local:8000', client: MockClient((r) async {
      if (r.url.path == '/status') {
        return _json({
          'running': false,
          'job_id': null,
          'last_job_id': null,
          'routine_run_id': 'job-1',
          'routine_status': 'running',
          'routine_segment': 2,
          'routine_segment_job_id': 'job-2',
        });
      }
      if (r.url.path == '/jobs/job-1') return _json(_rootRunning());
      return _json({'detail': 'unexpected'}, 404);
    }));
    final c = container(api);
    final n = c.read(executionStatusProvider.notifier);
    final id = n.beginSubmitting(api: api, label: '저녁 루틴');
    n.beginSubmissionUnknown(api: api, label: '저녁 루틴', requestId: id);

    await Future<void>.delayed(const Duration(milliseconds: 2500));
    final s = c.read(executionStatusProvider);
    expect(s.sequenceId, 'job-1');
    expect(s.phase, ExecutionPhase.running);
  });

  test('옛 본체(루틴 필드 없음)는 종전대로 그 구간의 끝을 결과로 본다', () async {
    final api = RpiApiService('http://rpi5.local:8000',
        client: MockClient((r) async => _json(_segmentDone(routine: false))));
    final c = container(api);
    c.read(executionStatusProvider.notifier).beginHttpJob(api: api, jobId: 'job-2', label: '저녁 루틴');
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    final s = c.read(executionStatusProvider);
    expect(s.sequenceId, 'job-2');
    expect(s.phase, ExecutionPhase.completed);
  });
}
