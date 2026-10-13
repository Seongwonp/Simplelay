// 정지 보고의 실행 결속(외부 평가 2026-10-13 H1·M1) — 실제 ExecutionStatusNotifier와 RpiApiService 배선.
//
// H1: J1 정지 요청 → J1 종료 → J2 시작(빠르게 끝남) → J1의 정지 응답이 늦게 도착해도 J2 화면에 J1의
//     "멈춘 것을 확인했어요"가 붙지 않는다.
// M1: 실행 결과(stopped)가 먼저 오고 정지 확인 단계가 늦게 오면, 같은 job이면 짧은 후속 조회로 화면 문구를
//     고친다(음성 재낭독은 하지 않는다). 다른 단말에서 멈춘 경우·옛 RPi4(보고 없음)도 본다.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/tts_provider.dart';
import 'package:simplelay/services/app_tts_service.dart';
import 'package:simplelay/services/rpi_api_service.dart';

class _CountingTts extends AppTtsService {
  final spoken = <String>[];
  @override
  Future<void> speak(String text) async => spoken.add(text);
}

http.Response _json(Object body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

/// /status는 [status]가 그때 돌려주는 값, /stop은 [stop]이 끝날 때까지 붙잡는다.
RpiApiService _api({
  required Map<String, dynamic> Function() status,
  Future<Map<String, dynamic>> Function()? stop,
}) =>
    RpiApiService('http://rpi5.local:8000',
        client: MockClient((request) async => request.url.path == '/stop'
            ? _json(await (stop ?? () async => {'ok': true})())
            : _json(status())));

Map<String, dynamic> _running(String job) =>
    {'running': true, 'job_id': job, 'last_job_id': null, 'last_status': null};

Map<String, dynamic> _stopped(String job,
        {String? level, int? ackMs, String? stopJob, bool newServer = true}) =>
    {
      'running': false,
      'job_id': null,
      'last_job_id': job,
      'last_status': 'safety_stopped',
      'last_outcome': 'stopped',
      'last_execution_mode': 'real',
      'last_buttons': [],
      'last_stop_level': level,
      'last_stop_ack_ms': ackMs,
      if (newServer) 'last_stop_job_id': stopJob,
    };

Future<void> _until(bool Function() cond, {int ms = 6000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('조건을 기다리다 기한이 지났다');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late _CountingTts tts;
  ProviderContainer container() {
    tts = _CountingTts();
    final c = ProviderContainer(
        overrides: [ttsServiceProvider.overrideWithValue(tts)]);
    addTearDown(c.dispose);
    return c;
  }

  group('H1 — 이전 정지의 늦은 응답', () {
    for (final newServer in [true, false]) {
      test(
          'J1 정지 → J1 종료 → J2 시작·완료 → J1 정지 응답 지연: J2 화면을 덮지 않는다'
          '${newServer ? '' : ' (stop_job_id 없는 옛 서버)'}', () async {
        final c = container();
        final notifier = c.read(executionStatusProvider.notifier);
        final stopGate = Completer<Map<String, dynamic>>();
        var j1Status = _running('J1');
        final j1Api =
            _api(status: () => j1Status, stop: () => stopGate.future);
        notifier.beginHttpJob(api: j1Api, jobId: 'J1', label: '아침 데우기');
        final stopFuture = notifier.emergencyStop();
        j1Status = _stopped('J1', newServer: newServer); // J1은 정지로 끝났다, 보고는 아직
        await _until(() => c.read(executionStatusProvider).phase != ExecutionPhase.running);

        final j2Api = _api(status: () => {
              'running': false,
              'job_id': null,
              'last_job_id': 'J2',
              'last_status': 'succeeded',
              'last_outcome': 'success',
              'last_execution_mode': 'mock',
              'last_buttons': [],
            });
        notifier.beginHttpJob(api: j2Api, jobId: 'J2', label: '저녁 데우기');
        await _until(() => c.read(executionStatusProvider).phase == ExecutionPhase.completed);
        final j2Message = c.read(executionStatusProvider).message;

        stopGate.complete({
          'ok': true,
          'was_running': true,
          'stop_level': 'verified',
          'stop_ack_ms': 9,
          'stop_confirmed': true,
          if (newServer) 'stop_job_id': 'J1',
        });
        expect(await stopFuture, isTrue); // 정지는 보냈다
        final s = c.read(executionStatusProvider);
        expect(s.sequenceId, 'J2');
        expect(s.phase, ExecutionPhase.completed);
        expect(s.message, j2Message);
        expect(s.message, isNot(contains('멈춘 것을 확인했어요')));
      });
    }

    test('/status의 정지 단계가 다른 실행의 것이면 내 결과 문장에 싣지 않는다', () async {
      final c = container();
      c.read(executionStatusProvider.notifier).beginHttpJob(
            api: _api(
                status: () =>
                    _stopped('J1', level: 'verified', ackMs: 8, stopJob: 'J0')),
            jobId: 'J1',
            label: '아침 데우기',
          );
      await _until(() => c.read(executionStatusProvider).phase != ExecutionPhase.running);
      expect(c.read(executionStatusProvider).message,
          '실행을 멈췄어요. 장치가 멈췄는지 확인해 주세요.');
    });

    test('정지 응답이 다른 실행(stop_job_id)을 멈췄다고 하면 단계를 내 화면에 쓰지 않는다', () async {
      final c = container();
      final notifier = c.read(executionStatusProvider.notifier);
      notifier.beginHttpJob(
        api: _api(
            status: () => _running('J1'),
            stop: () async => {
                  'ok': true,
                  'stop_level': 'verified',
                  'stop_ack_ms': 5,
                  'stop_confirmed': true,
                  'stop_job_id': 'JX',
                }),
        jobId: 'J1',
        label: '아침 데우기',
      );
      expect(await notifier.emergencyStop(), isTrue);
      expect(c.read(executionStatusProvider).message, '정지 요청을 보냈어요.');
    });
  });

  group('M1 — 결과가 먼저, 정지 단계가 나중', () {
    test('내 정지: 결과(stopped)가 먼저 오고 정지 응답이 늦게 와도 같은 job이면 결과 문장을 고친다(음성 재낭독 없음)',
        () async {
      final c = container();
      final notifier = c.read(executionStatusProvider.notifier);
      final stopGate = Completer<Map<String, dynamic>>();
      var status = _running('J1');
      notifier.beginHttpJob(
          api: _api(status: () => status, stop: () => stopGate.future),
          jobId: 'J1',
          label: '아침 데우기');
      final stopFuture = notifier.emergencyStop();
      status = _stopped('J1'); // 결과 먼저, 단계는 아직 없음
      await _until(() => c.read(executionStatusProvider).phase != ExecutionPhase.running);
      expect(c.read(executionStatusProvider).message,
          '실행을 멈췄어요. 장치가 멈췄는지 확인해 주세요.');
      final spoken = tts.spoken.length;
      stopGate.complete({
        'ok': true,
        'stop_level': 'verified',
        'stop_ack_ms': 9,
        'stop_confirmed': true,
        'stop_job_id': 'J1',
      });
      await stopFuture;
      final s = c.read(executionStatusProvider);
      expect(s.sequenceId, 'J1');
      expect(s.outcome, 'stopped');
      expect(s.message, '실행을 멈췄어요. 멈춘 것을 확인했어요 (9 ms).');
      expect(tts.spoken.length, spoken);
    });

    test('다른 단말에서 멈춘 실행: 정지 단계가 /status에 늦게 오면 짧은 후속 조회로 문장을 고친다', () async {
      final c = container();
      var status = _stopped('J1');
      c.read(executionStatusProvider.notifier).beginHttpJob(
          api: _api(status: () => status), jobId: 'J1', label: '아침 데우기');
      await _until(() => c.read(executionStatusProvider).phase != ExecutionPhase.running);
      expect(c.read(executionStatusProvider).message,
          '실행을 멈췄어요. 장치가 멈췄는지 확인해 주세요.');
      final spoken = tts.spoken.length;
      status = _stopped('J1', level: 'mcu_ack', ackMs: 12, stopJob: 'J1');
      await _until(() => c.read(executionStatusProvider).message?.contains('모션 보드') ?? false);
      expect(c.read(executionStatusProvider).message,
          '실행을 멈췄어요. 모션 보드가 정지를 확인했어요 (12 ms).');
      expect(tts.spoken.length, spoken);
    });

    test('옛 RPi4(정지 보고 없음): 후속 조회는 몇 번에서 멈추고 단계를 지어내지 않는다', () async {
      final c = container();
      var calls = 0;
      c.read(executionStatusProvider.notifier).beginHttpJob(
          api: _api(status: () {
            calls++;
            return _stopped('J1');
          }),
          jobId: 'J1',
          label: '아침 데우기');
      await _until(() => c.read(executionStatusProvider).phase != ExecutionPhase.running);
      final after = calls;
      await Future<void>.delayed(const Duration(milliseconds: 5000));
      expect(calls - after, lessThanOrEqualTo(3));
      expect(c.read(executionStatusProvider).message,
          '실행을 멈췄어요. 장치가 멈췄는지 확인해 주세요.');
    });

    test('후속 조회 중 새 실행이 시작되면 옛 단계를 새 화면에 싣지 않는다', () async {
      final c = container();
      final notifier = c.read(executionStatusProvider.notifier);
      var j1 = _stopped('J1');
      notifier.beginHttpJob(api: _api(status: () => j1), jobId: 'J1', label: '아침 데우기');
      await _until(() => c.read(executionStatusProvider).phase != ExecutionPhase.running);
      notifier.beginHttpJob(
          api: _api(status: () => _running('J2')), jobId: 'J2', label: '저녁 데우기');
      j1 = _stopped('J1', level: 'verified', ackMs: 3, stopJob: 'J1');
      await Future<void>.delayed(const Duration(milliseconds: 3500));
      final s = c.read(executionStatusProvider);
      expect(s.sequenceId, 'J2');
      expect(s.message, isNot(contains('멈춘 것을 확인했어요')));
    });
  });
}
