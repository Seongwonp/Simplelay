// 리뷰 지적 #4 회귀 — 내 job(J1) 완료 직후 다른 클라이언트의 J2가 시작되면
// /status가 {running: true, job_id: J2, last_job_id: J1}이 된다. running을
// 먼저 처리하던 이전 로직은 J1의 완료를 영영 놓치고 화면이 고착됐다.
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

class FakeAppTts extends AppTtsService {
  @override
  Future<void> speak(String text) async {}
}

/// /stop 호출 횟수를 세는 mock -- '확인 불가'에서도 정지가 실제로 서버로
/// 나가는지 확인하기 위해.
RpiApiService _apiCountingStops(
  Map<String, dynamic> statusBody,
  void Function() onStop,
) {
  final client = MockClient((request) async {
    if (request.url.path == '/stop') {
      onStop();
      return http.Response('{}', 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }
    return http.Response.bytes(
      utf8.encode(jsonEncode(statusBody)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
  return RpiApiService('http://rpi5.local:8000', client: client);
}

RpiApiService _apiReturning(Map<String, dynamic> statusBody) {
  final client = MockClient((request) async => http.Response.bytes(
        utf8.encode(jsonEncode(statusBody)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ));
  return RpiApiService('http://rpi5.local:8000', client: client);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('다른 job이 이어서 실행 중이어도 내 job의 완료를 놓치지 않는다', () async {
    final container = ProviderContainer(
      overrides: [ttsServiceProvider.overrideWithValue(FakeAppTts())],
    );
    addTearDown(container.dispose);

    container.read(executionStatusProvider.notifier).beginHttpJob(
          api: _apiReturning({
            'running': true, // J2가 이미 실행 중 (추월)
            'job_id': 'J2',
            'last_job_id': 'J1', // 하지만 내 J1은 완료됐다
            'last_status': 'succeeded',
            'last_buttons': [],
          }),
          jobId: 'J1',
          label: '우유 데워줘',
        );
    await Future<void>.delayed(const Duration(milliseconds: 1500));

    final state = container.read(executionStatusProvider);
    expect(state.phase, ExecutionPhase.completed);
  });

  test('내 job의 흔적이 계속 없으면 고착 대신 확인 불가로 탈출한다', () async {
    var stopCalls = 0;
    final container = ProviderContainer(
      overrides: [ttsServiceProvider.overrideWithValue(FakeAppTts())],
    );
    addTearDown(container.dispose);

    container.read(executionStatusProvider.notifier).beginHttpJob(
          api: _apiCountingStops({
            // 서버 재시작 등 — 내 J1의 흔적이 어디에도 없다
            'running': false,
            'job_id': null,
            'last_job_id': null,
            'last_status': null,
          }, () => stopCalls++),
          jobId: 'J1',
          label: '우유 데워줘',
        );
    // 폴링 1초 × 10회 임계 초과까지 대기
    await Future<void>.delayed(const Duration(milliseconds: 11500));

    // 실패가 아니라 '모름'이다 -- 통신이 끊긴 것이지 가전이 멈춘 게 아니라,
    // 정지·재확인 수단을 남긴 채 사용자에게 직접 확인을 청해야 한다.
    final state = container.read(executionStatusProvider);
    expect(state.phase, ExecutionPhase.unknown);
    expect(state.message, contains('확인할 수 없어요'));

    // 그리고 정지 수단이 남아 있어야 한다. 추적 대상을 지워버리면
    // emergencyStop이 HTTP 경로를 잃고 BLE로 빠져 실제로 멈추지 못한다.
    await container.read(executionStatusProvider.notifier).emergencyStop();
    expect(stopCalls, 1);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
