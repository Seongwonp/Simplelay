// 폐루프 증거(현재 버튼·단계·센서 검증)가 서버 JSON에서 화면 상태까지
// 실제로 도착하는지 — 계층을 건너뛰지 않고 통과시켜 확인한다.
//
// 이 제품의 차별점은 "실제 버튼을 누르고 센서로 확인한다"는 것이다. 서버가
// 그 근거를 보내도 앱 모델·provider에서 떨어뜨리면 사용자에겐 "빙글빙글 돌다
// 완료되는 앱"이 된다. 그 회귀를 막는 테스트.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/services/rpi_api_service.dart';

/// 실기기가 실제로 주는 모양의 /status 응답(실행 중 + 검증 근거).
RpiApiService _apiRunningWithEvidence(String jobId) {
  final client = MockClient((request) async {
    return http.Response.bytes(
      utf8.encode(jsonEncode({
        'running': true,
        'last_status': null,
        'last_buttons': null,
        'current_button': '1분 추가',
        'current_attempt': 1,
        'completed_steps': 1,
        'total_steps': 3,
        'verification_confidence': 0.93,
        'verification_detail': '센서로 눌림 확인',
        'job_id': jobId,
        'last_job_id': null,
      })),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
  return RpiApiService('http://rpi5.local:8000', client: client);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('서버의 현재 버튼·단계·검증 근거가 실행 상태까지 도착한다', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(executionStatusProvider.notifier).beginHttpJob(
          api: _apiRunningWithEvidence('job-1'),
          jobId: 'job-1',
          label: '즉석밥 데워줘',
          // 음성 실행처럼 미리보기가 비어 있어도 진행이 보여야 한다
          steps: const [],
        );

    // 1초 주기 폴링이 한 번 돌 때까지 대기
    await Future<void>.delayed(const Duration(milliseconds: 1500));

    final status = container.read(executionStatusProvider);
    expect(status.phase, ExecutionPhase.running);
    expect(status.currentButton, '1분 추가');
    expect(status.completedSteps, 1);
    // steps 미리보기가 없어도 서버의 total_steps로 진행을 알 수 있다
    expect(status.totalSteps, 3);
    expect(status.verificationConfidence, closeTo(0.93, 0.001));
    expect(status.verificationDetail, '센서로 눌림 확인');
  });
}
