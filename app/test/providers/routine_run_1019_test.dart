// 검토 10/19: 루틴 승인의 첫 번호는 루틴 실행 전체의 수명이다(본체 GET /jobs — 루틴이 도는 동안 running·finished=false,
// routine_run_id 등). 폰은 루틴이 도는 동안 '하는 중'(지금 구간)으로 보이고 정지를 남기며, 정지는 그 루틴만 멈추는
// /routines/runs/{id}/stop으로 보낸다(없으면 /stop). 끝남은 finished=true에서만.
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

/// 루틴이 구간 사이에서 기다리는 중인 첫 번호의 GET /jobs.
Map<String, dynamic> _routineWaiting({int segment = 2}) => {
      'running': true,
      'finished': false,
      'job_id': 'job-1',
      'last_job_id': null,
      'routine_run_id': 'job-1',
      'routine_status': 'running',
      'routine_segment': segment,
      'routine_segment_job_id': 'job-$segment',
    };

Map<String, dynamic> _routineStopped() => {
      'running': false,
      'finished': true,
      'job_id': null,
      'last_job_id': 'job-1',
      'last_status': 'stopped',
      'last_outcome': 'stopped',
      'routine_run_id': 'job-1',
      'routine_status': 'stopped',
      'routine_segment': 2,
      'routine_segment_job_id': 'job-2',
      'routine_detail': '루틴을 멈췄어요',
      'last_stop_level': 'mcu_ack',
      'last_stop_ack_ms': 12,
      'last_stop_job_id': 'job-2',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer track(RpiApiService api) {
    final c = ProviderContainer(overrides: [rpiApiServiceProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    c.read(executionStatusProvider.notifier).beginHttpJob(api: api, jobId: 'job-1', label: '저녁 루틴');
    return c;
  }

  test('루틴이 구간 사이에서 기다리는 동안 하는 중이고 지금 구간을 말한다', () async {
    final api = RpiApiService('http://rpi5.local:8000',
        client: MockClient((r) async => _json(_routineWaiting())));
    final c = track(api);
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    final s = c.read(executionStatusProvider);
    expect(s.phase, ExecutionPhase.running);
    expect(s.message, contains('2번째'));
  });

  test('구간의 진행 칸 수를 루틴 전체 칸으로 싣지 않는다', () async {
    final api = RpiApiService('http://rpi5.local:8000', client: MockClient((r) async {
      return _json({
        ..._routineWaiting(segment: 1),
        'completed_steps': 1,
        'total_steps': 1,
        'current_button': '전원',
      });
    }));
    final c = track(api);
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    final s = c.read(executionStatusProvider);
    expect(s.phase, ExecutionPhase.running);
    expect(s.totalSteps, isNull, reason: '구간 하나의 칸 수는 루틴 전체가 아니다');
    expect(s.completedSteps, 0);
  });

  test('끝남이 아니면(finished=false) 마지막 번호가 같아도 끝내지 않는다', () async {
    final api = RpiApiService('http://rpi5.local:8000', client: MockClient((r) async {
      return _json({
        ..._routineWaiting(),
        'running': false,
        'job_id': null,
        'last_job_id': 'job-1',
        'last_status': 'succeeded',
        'last_outcome': 'success',
      });
    }));
    final c = track(api);
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(c.read(executionStatusProvider).phase, isNot(ExecutionPhase.completed));
  });

  test('정지는 그 루틴만 멈추는 경로로 보내고, 끝나면 루틴 결과와 그 구간의 정지 단계를 싣는다', () async {
    final paths = <String>[];
    var stopped = false;
    final api = RpiApiService('http://rpi5.local:8000', client: MockClient((r) async {
      paths.add('${r.method} ${r.url.path}');
      if (r.url.path == '/routines/runs/job-1/stop') {
        stopped = true;
        return _json({'ok': true});
      }
      if (r.url.path == '/stop') return _json({'stop_level': 'sent'});
      return _json(stopped ? _routineStopped() : _routineWaiting());
    }));
    final c = track(api);
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    final sent = await c.read(executionStatusProvider.notifier).emergencyStop();
    expect(sent, isTrue);
    expect(paths, contains('POST /routines/runs/job-1/stop'));
    expect(paths, isNot(contains('POST /stop')));
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    final s = c.read(executionStatusProvider);
    expect(s.phase, ExecutionPhase.failed);
    expect(s.outcome, 'stopped');
    expect(s.message, contains('신호를 받았어요'), reason: '구간 정지의 단계(mcu_ack)도 이 루틴의 것');
  });

  test('루틴 정지 경로가 거절하면(진행 중인 루틴 아님) 본체 전체 정지로 갈음한다', () async {
    final paths = <String>[];
    final api = RpiApiService('http://rpi5.local:8000', client: MockClient((r) async {
      paths.add('${r.method} ${r.url.path}');
      if (r.url.path == '/routines/runs/job-1/stop') {
        return _json({'detail': '진행 중인 루틴 실행이 아니에요'}, 409);
      }
      if (r.url.path == '/stop') return _json({'stop_level': 'sent', 'stop_job_id': null});
      return _json(_routineWaiting());
    }));
    final c = track(api);
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    final sent = await c.read(executionStatusProvider.notifier).emergencyStop();
    expect(sent, isTrue);
    expect(paths, containsAllInOrder(['POST /routines/runs/job-1/stop', 'POST /stop']));
  });

  test('루틴 번호를 아직 모르면(첫 조회 전) 종전처럼 /stop', () async {
    final paths = <String>[];
    final api = RpiApiService('http://rpi5.local:8000', client: MockClient((r) async {
      paths.add('${r.method} ${r.url.path}');
      if (r.url.path == '/stop') return _json({'stop_level': 'sent'});
      return _json(_routineWaiting());
    }));
    final c = track(api);
    await c.read(executionStatusProvider.notifier).emergencyStop();
    expect(paths, contains('POST /stop'));
    expect(paths.where((p) => p.startsWith('POST /routines')), isEmpty);
  });
}
