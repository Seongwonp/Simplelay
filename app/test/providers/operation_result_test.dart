// /status의 2026-09-29 필드(last_retry_count·last_operation_*)를 실행 추적이
// 읽는지. 판정기가 없으면 null이고, 화면이 0이나 false로 지어내지 않는다.
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
  @override
  Future<void> speak(String text) async {}
}

RpiApiService _api(Map<String, dynamic> statusBody) => RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((request) async => http.Response.bytes(
            utf8.encode(jsonEncode(statusBody)),
            200,
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
        label: '즉석밥 데워줘',
      );
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  return container.read(executionStatusProvider);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('L3 확인·판정 입력·사유와 재시도 수를 그대로 읽는다', () async {
    final s = await _finish({
      'last_status': 'succeeded',
      'last_outcome': 'success',
      'last_route': 'physical',
      'last_confirmation': 'operation_confirmed',
      'last_execution_mode': 'real',
      'last_retry_count': 1,
      'last_operation_confirmed': true,
      'last_operation_source': 'mock',
      'last_operation_detail': '전력 파형에서 가열 시작을 확인했어요',
    });
    expect(s.phase, ExecutionPhase.completed);
    expect(s.retryCount, 1);
    expect(s.operationConfirmed, isTrue);
    expect(s.operationSource, 'mock');
    expect(s.operationDetail, '전력 파형에서 가열 시작을 확인했어요');
  });

  test('판정기가 없으면 null이다 — 0·false로 지어내지 않는다', () async {
    final s = await _finish({
      'last_status': 'succeeded',
      'last_outcome': 'success',
      'last_route': 'physical',
      'last_confirmation': 'press_confirmed',
      'last_execution_mode': 'real',
    });
    expect(s.retryCount, isNull);
    expect(s.operationConfirmed, isNull);
    expect(s.operationSource, isNull);
  });

  test('L3 미확인(false)은 실패가 아니지만 확인했다고 올리지 않는다', () async {
    final s = await _finish({
      'last_status': 'succeeded',
      'last_outcome': 'success',
      'last_route': 'physical',
      'last_execution_mode': 'real',
      'last_operation_confirmed': false,
      'last_operation_detail': '전력 변화가 없었어요',
    });
    expect(s.phase, ExecutionPhase.completed);
    expect(s.operationConfirmed, isFalse);
  });
}
