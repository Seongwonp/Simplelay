/// R2 — "실제 조작이 아닙니다"라고 말할 때는 실제로 아무것도 보내지 않는다.
///
/// 어제(B7) 데모 게이트를 만들면서 막은 것은 **BLE 가짜 센서 주입**뿐이었다.
/// HTTP 실행은 그대로 서버로 나갔다. 그래서 데모 모드를 켜고 제안을 승인하면
/// **실제 갠트리가 움직이는데 화면은 "실제 조작이 아닙니다"라고 말했다.**
/// 폐루프의 존재 이유가 "눌림을 확인했는가"인데 그 확인을 화면이 뒤집는다.
///
/// 여기서 고정하는 계약은 두 가지다:
///   1. 모의 실행 = **실제 전송 0**. 화면 문구가 전송 차단을 대신하지 않는다.
///   2. 실제/모의 표시는 **그 job에** 새겨진다. 진행 중 전역 토글을 건드려도
///      이미 시작한 작업의 표시는 바뀌지 않는다.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/demo_provider.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/providers/tts_provider.dart';
import 'package:simplelay/services/app_tts_service.dart';

class _FakeTts extends AppTtsService {
  @override
  Future<void> speak(String text) async {}
}

/// 실행 계열 요청이 실제로 나갔는지만 센다. 읽기(폴링)는 통과시킨다.
class _RequestLog {
  final List<String> executes = [];
  final List<String> reads = [];

  http.Client client() => MockClient((request) async {
        final path = request.url.path;
        const executePaths = {
          '/execute',
          '/execute-buttons',
          '/execute-for-appliance',
        };
        if (executePaths.contains(path) || path.endsWith('/approve')) {
          executes.add(path);
          return _json({'job_id': 'REAL-1'});
        }
        reads.add(path);
        if (path == '/status') {
          return _json({'running': false, 'job_id': null, 'last_job_id': null});
        }
        return _json({});
      });
}

http.Response _json(Map<String, dynamic> body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Future<ProviderContainer> _container(
  _RequestLog log, {
  required bool demo,
}) async {
  SharedPreferences.setMockInitialValues({
    'rpi_base_url': 'http://rpi5.local:8000',
    'demo_mode': demo,
  });
  final container = ProviderContainer(
    overrides: [
      ttsServiceProvider.overrideWithValue(_FakeTts()),
      rpiHttpClientProvider.overrideWithValue(log.client()),
    ],
  );
  addTearDown(container.dispose);
  // 주소·데모 플래그는 기기에서 비동기로 읽힌다 — 실제 앱과 같은 경로다.
  container.read(rpiUrlProvider);
  container.read(demoModeProvider);
  await Future<void>.delayed(Duration.zero);
  expect(container.read(demoModeProvider), demo);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('모의 실행은 실제로 아무것도 보내지 않는다', () {
    test('데모 모드에서 제안 승인이 서버로 나가지 않는다', () async {
      final log = _RequestLog();
      final container = await _container(log, demo: true);
      final api = container.read(rpiApiServiceProvider)!;

      final accepted = await api.approveSuggestion('suggestion-1');

      expect(log.executes, isEmpty, reason: '실제 전송이 있으면 배너가 거짓말이 된다');
      expect(accepted.jobId, isNotEmpty);
    });

    test('데모 모드에서 음성·수동 실행도 나가지 않는다', () async {
      final log = _RequestLog();
      final container = await _container(log, demo: true);
      final api = container.read(rpiApiServiceProvider)!;

      await api.execute('즉석밥 데워줘');
      await api.executeButtons(['시작']);
      await api.executeForAppliance('켜줘', ['전원'], applianceId: 'fan');

      expect(log.executes, isEmpty);
    });

    test('데모가 꺼져 있으면 그대로 실제로 나간다', () async {
      final log = _RequestLog();
      final container = await _container(log, demo: false);
      final api = container.read(rpiApiServiceProvider)!;

      await api.execute('즉석밥 데워줘');

      expect(log.executes, ['/execute']);
    });

    test('모의 실행도 완료까지 진행한다 — 데모가 성립해야 한다', () async {
      final log = _RequestLog();
      final container = await _container(log, demo: true);
      final api = container.read(rpiApiServiceProvider)!;

      final accepted = await api.execute('즉석밥 데워줘');
      container.read(executionStatusProvider.notifier).beginHttpJob(
            api: api,
            jobId: accepted.jobId,
            label: '즉석밥 데워줘',
            steps: const ['해동', '시작'],
          );
      await Future<void>.delayed(const Duration(milliseconds: 4000));

      expect(
        container.read(executionStatusProvider).phase,
        ExecutionPhase.completed,
      );
      expect(log.executes, isEmpty);
    });
  });

  group('실제/모의 표시는 그 job에 새겨진다', () {
    test('모의로 시작한 job은 모의로 표시된다', () async {
      final log = _RequestLog();
      final container = await _container(log, demo: true);
      final api = container.read(rpiApiServiceProvider)!;

      container.read(executionStatusProvider.notifier).beginHttpJob(
            api: api,
            jobId: 'demo-1',
            label: '즉석밥 데워줘',
          );

      expect(container.read(executionStatusProvider).isDemo, isTrue);
    });

    test('진행 중 전역 토글을 꺼도 현재 작업의 표시는 그대로다', () async {
      // 켠 채로 시작한 작업이 도중에 "실제 실행"으로 둔갑하면 안 된다.
      final log = _RequestLog();
      final container = await _container(log, demo: true);
      final api = container.read(rpiApiServiceProvider)!;

      container.read(executionStatusProvider.notifier).beginHttpJob(
            api: api,
            jobId: 'demo-1',
            label: '즉석밥 데워줘',
          );
      container.read(demoModeProvider.notifier).state = false;

      expect(container.read(executionStatusProvider).isDemo, isTrue);
    });

    test('실제로 시작한 job은 나중에 데모를 켜도 실제로 표시된다', () async {
      final log = _RequestLog();
      final container = await _container(log, demo: false);
      final api = container.read(rpiApiServiceProvider)!;

      container.read(executionStatusProvider.notifier).beginHttpJob(
            api: api,
            jobId: 'REAL-1',
            label: '즉석밥 데워줘',
          );
      container.read(demoModeProvider.notifier).state = true;

      expect(container.read(executionStatusProvider).isDemo, isFalse);
    });
  });
}
