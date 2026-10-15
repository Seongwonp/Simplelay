// 정지 확인 단계(2026-10-13) — 폰이 '보냄'과 '확인'을 가른다.
//
// 서버는 정지의 확인 단계를 sent(정지 명령을 보냄) · mcu_ack(모션 보드가 받음, 지연 ms) ·
// verified(엔코더로 멈춤 확인)로 올린다. mcu_ack 이상만 '확인'이다. 단계가 없으면(옛 서버·
// 로컬 모의) 종전 문장을 그대로 쓴다 — 단계를 지어내지 않는다.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/command_result.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/tts_provider.dart';
import 'package:simplelay/services/app_tts_service.dart';
import 'package:simplelay/services/dev_api_service.dart';
import 'package:simplelay/services/rpi_api_service.dart';

class _QuietTts extends AppTtsService {
  @override
  Future<void> speak(String text) async {}
}

http.Response _json(Object body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

RpiApiService _api({
  required Map<String, dynamic> status,
  Map<String, dynamic> stop = const {'ok': true},
}) =>
    RpiApiService('http://rpi5.local:8000',
        client: MockClient((request) async =>
            _json(request.url.path == '/stop' ? stop : status)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('stopLevelSentence', () {
    test('단계마다 다른 문장 — 보냄은 확인이라고 하지 않는다', () {
      expect(stopLevelSentence('sent'), '멈추라고 보냈어요 — 멈췄는지 아직 몰라요');
      expect(stopLevelSentence('mcu_ack', ackMs: 12), '누름 장치가 정지 신호를 받았어요 — 멈췄는지는 확인 못 했어요');
      // 개발자 도구만 ms를 함께 보인다(2026-10-14 UX — 사용자 화면은 숫자 없이).
      expect(stopLevelSentence('mcu_ack', ackMs: 12, detail: true), '모션 보드가 정지를 확인했어요 (12 ms)');
      expect(stopLevelSentence('mcu_ack'), '누름 장치가 정지 신호를 받았어요 — 멈췄는지는 확인 못 했어요');
      // ack_ms는 정지를 보낸 뒤 모션 보드 응답까지다 — 멈춤 확인(verified)까지의 시간이 아니다(외부 평가 L2).
      expect(stopLevelSentence('verified', ackMs: 9), '누름 장치가 멈췄어요');
      expect(stopLevelSentence('verified', ackMs: 9, detail: true), '멈춘 것을 확인했어요 (모션 보드 응답 9 ms)');
      expect(stopLevelSentence(null), isNull);
      expect(stopLevelSentence('stopped_for_sure'), isNull);
      expect(stopLevelConfirmed('sent'), isFalse);
      expect(stopLevelConfirmed('mcu_ack'), isTrue);
      expect(stopLevelConfirmed('verified'), isTrue);
    });

    test('멈춘 실행의 끝 문장은 정지 단계를 따른다', () {
      expect(finishedMessage(kind: ResultKind.stopped),
          '정지 요청으로 실행이 끝났어요. 누름 장치와 가전이 멈췄는지 직접 봐 주세요.');
      expect(finishedMessage(kind: ResultKind.stopped, stopLevel: 'sent'),
          '멈추라고 보냈어요. 멈췄는지 아직 몰라요. 가전을 직접 봐 주세요.');
      expect(
          finishedMessage(
              kind: ResultKind.stopped, stopLevel: 'mcu_ack', stopAckMs: 30),
          '누름 장치가 정지 신호를 받았어요. 멈췄는지는 확인 못 했어요. 가전을 직접 봐 주세요.');
      expect(finishedMessage(kind: ResultKind.stopped, stopLevel: 'verified'),
          '누름 장치가 멈췄어요. 가전이 이미 켜졌다면 가전의 정지·취소 버튼을 직접 눌러 주세요.');
    });
  });

  group('서버 응답 읽기', () {
    test('POST /stop의 정지 단계를 읽는다(옛 서버는 단계 없음)', () async {
      final sent = await _api(status: const {}, stop: const {
        'ok': true,
        'stop_level': 'mcu_ack',
        'stop_ack_ms': 14,
        'stop_confirmed': true,
      }).stop();
      expect(sent.stopLevel, 'mcu_ack');
      expect(sent.ackMs, 14);
      expect(sent.confirmed, isTrue);

      final old = await _api(status: const {}).stop();
      expect(old.stopLevel, isNull);
      expect(old.confirmed, isFalse);
    });

    test('개발자 정지 결과에 단계와 지연을 싣는다', () async {
      final api = DevApiService('http://rpi.test:8000',
          devToken: 't',
          client: MockClient((request) async => _json({
                'confirmed': false,
                'message': '정지 명령을 보냈어요',
                'stop_level': 'sent',
                'stop_ack_ms': null,
                'state': {
                  'phase': 'idle',
                  'mock': false,
                  'shutting_down': false,
                  'session': null,
                  'fault_reason': null,
                  'heartbeat_ttl_s': 2.0,
                  'max_jog_mm': 1.0,
                  'max_command_len': 64,
                  'allowed_commands': ['status'],
                },
              })));
      final result = await api.stop();
      expect(result.stopLevel, 'sent');
      expect(result.ackMs, isNull);
      expect(result.confirmed, isFalse);
    });
  });

  group('실행 화면', () {
    ProviderContainer container() {
      final c = ProviderContainer(
          overrides: [ttsServiceProvider.overrideWithValue(_QuietTts())]);
      addTearDown(c.dispose);
      return c;
    }

    test('정지 버튼의 안내는 서버가 알린 단계까지만 말한다', () async {
      final c = container();
      c.read(executionStatusProvider.notifier).beginHttpJob(
            api: _api(status: const {
              'running': true,
              'job_id': 'J1',
              'last_job_id': null,
              'last_status': null,
            }, stop: const {
              'ok': true,
              'stop_level': 'sent',
              'stop_ack_ms': null,
              'stop_confirmed': false,
            }),
            jobId: 'J1',
            label: '즉석밥 데워줘',
          );
      final sent = await c.read(executionStatusProvider.notifier).emergencyStop();
      expect(sent, isTrue);
      expect(c.read(executionStatusProvider).message,
          '멈추라고 보냈어요 — 멈췄는지 아직 몰라요');
    });

    test('단계가 없는 서버면 종전처럼 요청을 보냈다고만 한다', () async {
      final c = container();
      c.read(executionStatusProvider.notifier).beginHttpJob(
            api: _api(status: const {
              'running': true,
              'job_id': 'J1',
              'last_job_id': null,
              'last_status': null,
            }),
            jobId: 'J1',
            label: '즉석밥 데워줘',
          );
      await c.read(executionStatusProvider.notifier).emergencyStop();
      expect(c.read(executionStatusProvider).message, '정지 요청을 보냈어요.');
    });

    test('멈춘 실행의 결과 문장에 마지막 정지 단계를 싣는다', () async {
      final c = container();
      c.read(executionStatusProvider.notifier).beginHttpJob(
            api: _api(status: const {
              'running': false,
              'job_id': null,
              'last_job_id': 'J1',
              'last_status': 'safety_stopped',
              'last_outcome': 'stopped',
              'last_buttons': [],
              'last_stop_level': 'verified',
              'last_stop_ack_ms': 8,
            }),
            jobId: 'J1',
            label: '즉석밥 데워줘',
          );
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(c.read(executionStatusProvider).message,
          '누름 장치가 멈췄어요. 가전이 이미 켜졌다면 가전의 정지·취소 버튼을 직접 눌러 주세요.');
    });
  });
}
