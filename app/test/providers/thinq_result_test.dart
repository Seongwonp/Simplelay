// /status의 last_outcome·route·receipt·confirmation을 실행 추적이 읽는지(2026-09-29).
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

class _FakeTts extends AppTtsService {
  final spoken = <String>[];
  @override
  Future<void> speak(String text) async => spoken.add(text);
}

RpiApiService _api(Map<String, dynamic> statusBody) => RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((request) async => http.Response.bytes(
            utf8.encode(jsonEncode(statusBody)),
            200,
            // 서버처럼 charset 없이 — 한글이 UTF-8 바이트로 풀려야 한다.
            headers: {'content-type': 'application/json'},
          )),
    );

Future<ExecutionStatus> _finish(Map<String, dynamic> body) async {
  final container = ProviderContainer(
    overrides: [ttsServiceProvider.overrideWithValue(_FakeTts())],
  );
  addTearDown(container.dispose);
  container.read(executionStatusProvider.notifier).beginHttpJob(
        api: _api({'running': false, 'last_job_id': 'J1', ...body}),
        jobId: 'J1',
        label: '공기청정기 켜기',
      );
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  return container.read(executionStatusProvider);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('ThinQ 확인 못 함은 실패가 아니라 unconfirmed 국면이다', () async {
    final s = await _finish({
      'last_status': 'unconfirmed',
      'last_outcome': 'unconfirmed',
      'last_route': 'thinq',
      'last_receipt': 'accepted',
      'last_confirmation': 'none',
      'last_detail': '상태를 확인하지 못했어요',
    });
    expect(s.phase, ExecutionPhase.unconfirmed);
    expect(s.message, contains('보냈지만 설정이 바뀌었는지 몰라요'));
    expect(s.route, 'thinq');
    expect(s.detail, '상태를 확인하지 못했어요');
  });

  test('접수 불명은 다시 보내기 전에 확인하라고 한다', () async {
    final s = await _finish({
      'last_status': 'unconfirmed',
      'last_outcome': 'unconfirmed',
      'last_route': 'thinq',
      'last_receipt': 'unknown',
      'last_confirmation': 'none',
    });
    expect(s.phase, ExecutionPhase.unconfirmed);
    expect(s.message, contains('받았는지 몰라요'));
    expect(s.message, contains('다시 보내기 전에'));
    // 실패도 성공도 말하지 않는다.
    expect(s.message, isNot(contains('못 했어요')));
    expect(s.message, isNot(contains('확인했어요')));
  });

  test('원격 안전 정지(safety_stop)는 "멈췄어요"가 아니라 안전 정지로 말한다', () async {
    final s = await _finish({
      'last_status': 'safety_stopped',
      'last_outcome': 'safety_stop',
      'last_route': 'physical',
    });
    expect(s.phase, ExecutionPhase.failed);
    expect(s.message, contains('눌렸는지 몰라서 멈췄어요'));
  });

  test('원격 실패(failed)는 정지 문구를 쓰지 않는다', () async {
    final s = await _finish({
      'last_status': 'safety_stopped',
      'last_outcome': 'failed',
      'last_route': 'physical',
    });
    expect(s.phase, ExecutionPhase.failed);
    // 접수 여부를 모르는 실패는 시작 못 함으로 단정하지 않는다(평가 M4).
    expect(s.message, '끝까지 하지 못했어요. 집에서 가전을 확인해야 해요.');
  });

  test('옛 서버(last_outcome 없음)의 safety_stopped는 종전 문구', () async {
    final s = await _finish({'last_status': 'safety_stopped'});
    expect(s.phase, ExecutionPhase.failed);
    expect(s.message, '멈추라고 해서 실행이 끝났어요. 누름 장치와 가전이 멈췄는지는 집에서 확인이 필요해요.');
    expect(s.outcome, isNull);
  });

  test('모의 ThinQ 상태 확인은 성공이되 실제 가전이 아니라고 말한다', () async {
    final s = await _finish({
      'last_status': 'succeeded',
      'last_outcome': 'success',
      'last_route': 'thinq',
      'last_receipt': 'accepted',
      'last_confirmation': 'state_confirmed',
      'last_execution_mode': 'mock',
    });
    expect(s.phase, ExecutionPhase.completed);
    expect(s.message, contains('실제 가전은 그대로예요'));
    expect(s.confirmation, 'state_confirmed');
  });
}
