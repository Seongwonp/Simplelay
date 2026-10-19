/// 앱을 다시 열어도 아까 맡긴 작업을 이어서 확인한다.
///
/// 실행은 수 초~수십 초 걸리고 그 사이 앱이 내려갈 수 있다(홈으로 나가거나
/// OS가 정리). job_id를 잃으면 물리 조작은 계속되는데 화면은 "실행한 적 없음"
/// 으로 돌아온다 — 가전 앞에 서 있는 사람에게 가장 나쁜 상태다.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/models/suggestion.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/providers/tts_provider.dart';
import 'package:simplelay/services/app_tts_service.dart';
import 'package:simplelay/services/rpi_api_service.dart';

class _FakeTts extends AppTtsService {
  @override
  Future<void> speak(String text) async {}
}

RpiApiService _apiReturning(Map<String, dynamic> body) {
  final client = MockClient((_) async => http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ));
  return RpiApiService('http://rpi5.local:8000', client: client);
}

final _hubChoice = StateProvider<RpiApiService?>((_) => null);

ProviderContainer _container(RpiApiService? api) {
  final container = ProviderContainer(
    overrides: [
      ttsServiceProvider.overrideWithValue(_FakeTts()),
      rpiApiServiceProvider.overrideWithValue(api),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('실행을 시작하면 job을 기기에 남긴다', () async {
    SharedPreferences.setMockInitialValues({});
    final container = _container(null);

    container.read(executionStatusProvider.notifier).beginHttpJob(
          api: _apiReturning({'running': true, 'job_id': 'J9'}),
          jobId: 'J9',
          label: '즉석밥 데워줘',
        );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('pending_job_id'), 'J9');
    expect(prefs.getString('pending_job_label'), '즉석밥 데워줘');
    expect(prefs.getString('pending_job_hub'), 'http://rpi5.local:8000', reason: '받은 본체도 함께 남긴다(검토 10/19)');
  });

  test('재시작하면 남은 job을 이어서 확인하고, 이미 끝났으면 결과를 보여준다', () async {
    // 앞선 실행이 남긴 흔적만 있는 상태에서 앱이 새로 뜬다.
    SharedPreferences.setMockInitialValues({
      'pending_job_id': 'J1',
      'pending_job_label': '즉석밥 데워줘',
    });
    final container = _container(_apiReturning({
      'running': false,
      'job_id': null,
      'last_job_id': 'J1', // 내가 맡긴 그 작업이 끝나 있다
      'last_status': 'succeeded',
      'last_buttons': [],
    }));

    // provider가 만들어지는 순간 복원이 시작된다.
    container.read(executionStatusProvider);
    await Future<void>.delayed(const Duration(milliseconds: 1500));

    final state = container.read(executionStatusProvider);
    expect(state.phase, ExecutionPhase.completed);
    expect(state.label, '즉석밥 데워줘');

    // 결말이 난 job은 더 이상 이어붙일 것이 없다.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('pending_job_id'), isNull);
  });

  test('남은 job이 아직 실행 중이면 실행 중 화면으로 이어붙인다', () async {
    SharedPreferences.setMockInitialValues({
      'pending_job_id': 'J1',
      'pending_job_label': '즉석밥 데워줘',
    });
    final container = _container(_apiReturning({
      'running': true,
      'job_id': 'J1',
      'completed_steps': 1,
      'total_steps': 3,
      'current_button': '1분 추가',
    }));

    container.read(executionStatusProvider);
    await Future<void>.delayed(const Duration(milliseconds: 1500));

    final state = container.read(executionStatusProvider);
    expect(state.phase, ExecutionPhase.running);
    expect(state.completedSteps, 1);
    expect(state.currentButton, '1분 추가');
  });

  test('남긴 job이 없으면 조용히 아무 일도 하지 않는다', () async {
    SharedPreferences.setMockInitialValues({});
    final container = _container(_apiReturning({'running': false}));

    container.read(executionStatusProvider);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(container.read(executionStatusProvider).phase, ExecutionPhase.idle);
  });

  // 검토 10/19(3): 본체 주소가 늦게 읽혀 옛 job 이어붙이기가 기다리는 사이 새 실행(BLE)이 시작됐다.
  // 주소가 그 뒤에 준비되면 옛 job이 새 실행 화면을 덮고, 정지는 옛 job을 겨누고 BLE 결과는 버려졌다.
  test('이어붙이기를 기다리는 사이 새 실행이 시작되면 옛 job으로 덮지 않는다', () async {
    SharedPreferences.setMockInitialValues({
      'pending_job_id': 'J1',
      'pending_job_label': '즉석밥 데워줘',
    });
    final container = _container(null);
    container.read(executionStatusProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    container.read(executionStatusProvider.notifier).begin(const Suggestion(
          sequenceId: 'ble-1',
          label: '공기청정기 켜기',
          steps: ['BT-01'],
        ));
    // 이제야 주소가 준비된다.
    container.updateOverrides([
      ttsServiceProvider.overrideWithValue(_FakeTts()),
      rpiApiServiceProvider.overrideWithValue(
          _apiReturning({'running': true, 'job_id': 'J1'})),
    ]);
    container.read(rpiApiServiceProvider);
    await Future<void>.delayed(const Duration(milliseconds: 1500));

    final state = container.read(executionStatusProvider);
    expect(state.sequenceId, 'ble-1');
    expect(state.phase, ExecutionPhase.waiting);
  });
  // 검토 10/19(5): 남은 job을 받은 본체가 아니라 지금 설정한 본체로 이어서 보고, 모름이 되면 정지를 지금 본체에 보내
  // 상관없는 실행을 멈출 수 있었다.
  test('다른 본체에서 받은 job은 지금 본체로 이어서 보지도 멈추지도 않고, 그 본체로 돌아오면 이어서 본다', () async {
    SharedPreferences.setMockInitialValues({
      'pending_job_id': 'JA',
      'pending_job_label': '즉석밥 데워줘',
      'pending_job_hub': 'http://hub-a.local:8000',
    });
    final calls = <String>[];
    final apiB = RpiApiService('http://hub-b.local:8000', client: MockClient((request) async {
      calls.add(request.url.path);
      return http.Response('{"running": true, "job_id": "JB"}', 200);
    }));
    final apiA = RpiApiService('http://hub-a.local:8000',
        client: MockClient((_) async => http.Response('{"running": true, "job_id": "JA"}', 200)));
    final container = ProviderContainer(overrides: [
      ttsServiceProvider.overrideWithValue(_FakeTts()),
      rpiApiServiceProvider.overrideWith((ref) => ref.watch(_hubChoice)),
    ]);
    addTearDown(container.dispose);
    container.read(_hubChoice.notifier).state = apiB;

    container.read(executionStatusProvider);
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    var status = container.read(executionStatusProvider);
    expect(status.phase, ExecutionPhase.unknown);
    expect(status.message, ExecutionStatusNotifier.foreignHubNotice);
    expect(calls, isEmpty, reason: '다른 본체에 상태를 묻지 않는다');

    final sent = await container.read(executionStatusProvider.notifier).emergencyStop();
    expect(sent, isFalse);
    expect(calls, isEmpty, reason: '다른 본체에 전체 정지를 보내지 않는다');
    expect(container.read(executionStatusProvider).message, ExecutionStatusNotifier.foreignHubStopNotice);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('pending_job_id'), 'JA', reason: '기록은 남긴다');

    container.read(_hubChoice.notifier).state = apiA;
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    status = container.read(executionStatusProvider);
    expect(status.sequenceId, 'JA');
    expect(status.phase, ExecutionPhase.running);
  });
}
